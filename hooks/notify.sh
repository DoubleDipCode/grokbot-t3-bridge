#!/bin/bash
# shellcheck disable=SC2016 # Single-quoted expressions are jq programs.
# Actionable Stop notifications; --sweep checks saved waiting worktrees.
HARNESS="${1:-unknown}"
DIR="${GROKBOT_HOOKS_DIR:-$HOME/.grokbot-hooks}"
STATE="${GROKBOT_STATE_DIR:-$DIR/state}"
STALE="${GROKBOT_STALE_SECONDS:-7200}"
case "$STALE" in *[!0-9]*|'') STALE=7200 ;; esac
LOG="$DIR/notify.log"
MAP="$DIR/markers.tsv"   # worktree<TAB>bot, so a removed or switched worktree can still be reported
[ -d "$DIR" ] || exit 0  # not installed
umask 077                # anything this script creates (log, map) is private to the user

# Prefer jq from PATH, fall back to /usr/bin/jq. Hooks often run with a minimal PATH.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"

# Keep the log bounded: one rotation at about 1 MB. no-marker lines are logged on every
# turn of your own sessions too, so this stops them piling up forever.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

process() {
ROOT="$1"
HARNESS="$2"
LAST="$3"
SESSION="${4:-}"
TRANSCRIPT="${5:-}"
SESSION_CWD="${6:-}"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
NOW="$(date +%s)"
if [ -f "$ROOT/.grokbot" ]; then
  # Bot name is sanitised so it can only ever point at a file inside $DIR.
  BOT="$(head -n1 "$ROOT/.grokbot" | tr -cd 'a-z0-9_-')"
  # Record or refresh worktree -> bot. Exact match on the path column, one line per
  # worktree, newest last, capped at 500 entries. Skipped when the line is already there.
  if [ -n "$BOT" ] && ! awk -F'\t' -v r="$ROOT" -v b="$BOT" '$1==r && $2==b {f=1} END{exit !f}' "$MAP" 2>/dev/null; then
    TMP="$(mktemp "$DIR/markers.XXXXXX" 2>/dev/null)" && {
      { awk -F'\t' -v r="$ROOT" '$1!=r' "$MAP" 2>/dev/null; printf '%s\t%s\n' "$ROOT" "$BOT"; } | tail -n 500 > "$TMP" \
        && chmod 600 "$TMP" && mv -f "$TMP" "$MAP"
      rm -f "$TMP" 2>/dev/null
    }
  fi
  STATUS_FILE="$ROOT/.grokbot-status"
  # Sentinel preserves trailing newlines for byte-exact dedupe of the payload.
  STATUS="$( { [ -f "$STATUS_FILE" ] && head -c 2000 "$STATUS_FILE" || printf turn_ended_no_status; }; printf '.')"
  STATUS="${STATUS%.}"
else
  # No marker. If we have seen this worktree before, the marker was removed with the
  # worktree, or the session is still running in an old path. Tell the bot anyway.
  BOT="$(awk -F'\t' -v r="$ROOT" '$1==r {b=$2} END{print b}' "$MAP" 2>/dev/null | tr -cd 'a-z0-9_-')"
  if [ -z "$BOT" ]; then
    # Always logged (no debug flag needed), so a missed callback is visible.
    echo "$TS $HARNESS no-marker $ROOT" >> "$LOG"
    return 0
  fi
  STATUS="worktree_missing worktree $ROOT no longer has a .grokbot marker (deleted or moved); read the thread for its real state"
fi

KEY="$(printf '%s' "$ROOT" | shasum -a 256 | awk '{print $1}')"
CACHE="$STATE/$KEY.json"
WORD="$(printf '%s' "$STATUS" | awk 'NR==1 {print $1}')"
CLOCK="$("$JQ" -r '.clock // empty' "$CACHE" 2>/dev/null)"
case "$CLOCK" in *[!0-9]*|'') CLOCK="$NOW" ;; esac
if [ "$WORD" = waiting ]; then
  if [ ! -f "$CACHE" ]; then
    "$JQ" -n --argjson clock "$NOW" '{clock:$clock}' > "$CACHE"
  fi
  if [ "$((NOW - CLOCK))" -lt "$STALE" ]; then
    echo "$TS $HARNESS skip=waiting $ROOT" >> "$LOG"
    return 0
  fi
  STATUS="stale $STATUS"
elif [ "$WORD" != needs_input ] && [ "$WORD" != failed ] &&
  "$JQ" -e --arg status "$STATUS" '.status == $status' "$CACHE" >/dev/null 2>&1; then
  echo "$TS $HARNESS skip=duplicate $ROOT" >> "$LOG"
  return 0
fi

BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
echo "$TS $HARNESS bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -n1 | head -c 80)" >> "$LOG"
ENV="$DIR/$BOT.env"
[ -f "$ENV" ] || return 0
GROKBOT_WEBHOOK_URL=
GROKBOT_WEBHOOK_AUTH=
# shellcheck disable=SC1090
. "$ENV"
[ -n "$GROKBOT_WEBHOOK_URL" ] || return 0
BODY="$("$JQ" -n --arg bot "$BOT" --arg harness "$HARNESS" --arg worktree "$ROOT" \
  --arg branch "$BRANCH" --arg status "$STATUS" --arg last "$LAST" --arg ts "$TS" \
  --arg session "$SESSION" --arg transcript "$TRANSCRIPT" --arg cwd "$SESSION_CWD" \
  '{event:"t3_turn_ended",bot:$bot,harness:$harness,worktree:$worktree,branch:$branch,status:$status,last_message:$last,ended_at:$ts,cwd:$cwd,session_id:$session,transcript_path:$transcript}')" || return 0
# Never log curl diagnostics: they can contain a secret URL.
HTTP="$(curl -sS -m 10 -X POST "$GROKBOT_WEBHOOK_URL" -H 'Content-Type: application/json' \
  ${GROKBOT_WEBHOOK_AUTH:+-H "Authorization: $GROKBOT_WEBHOOK_AUTH"} \
  --data "$BODY" -o /dev/null -w '%{http_code}' 2>/dev/null)"
RESULT=$?
echo "$TS $BOT webhook http=$HTTP result=$RESULT" >> "$LOG"
if [ "$RESULT" -eq 0 ] && [[ "$HTTP" = 2?? ]]; then
  "$JQ" -n --arg status "$STATUS" --argjson clock "$(date +%s)" \
    '{status:$status,clock:$clock}' > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
fi
}

sweep() {
  # Only waiting and missing markers need periodic attention. Do not replay done.
  while IFS=$'\t' read -r path bot; do
    [ -n "$path" ] && [ -n "$bot" ] || continue
    [ "$path" = "$CURRENT" ] && continue
    if [ ! -f "$path/.grokbot" ] ||
      [ "$(awk 'NR==1 {print $1; exit}' "$path/.grokbot-status" 2>/dev/null)" = waiting ]; then
      process "$path" sweep ""
    fi
  done < "$MAP"
}

worker() {
  [ -z "$CURRENT" ] || process "$CURRENT" "$HARNESS" "$MESSAGE" "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD"
  [ ! -f "$MAP" ] || sweep
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') worker-complete" >> "$LOG"
}

# Private entry point used only with an inherited locked file descriptor.
if [ "$HARNESS" = --worker ]; then
  HARNESS="$2"
  CURRENT="$3"
  MESSAGE="$4"
  SESSION_ID="${5:-}"
  TRANSCRIPT_PATH="${6:-}"
  CWD="${7:-}"
  worker
  exit 0
fi

locked_worker() {
  mkdir -p "$STATE" || return 0
  # Perl ships with macOS and shasum. Kernel flock releases on process exit;
  # no PID files or stale-lock deletion are needed. Keep the lock file in place.
  perl -MFcntl=:flock -e '
    $^F = 255; # Preserve the lock descriptor across exec into the worker.
    open my $lock, ">>", shift @ARGV or exit 0;
    flock($lock, LOCK_EX) or exit 0;
    exec @ARGV;
    exit 0;
  ' "$STATE/lock" /bin/bash "$0" --worker "$HARNESS" "$CURRENT" "$MESSAGE" "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD"
}

CURRENT=
SESSION_ID=
TRANSCRIPT_PATH=
CWD=
MESSAGE=
if [ "$HARNESS" != --sweep ]; then
  INPUT="$(cat 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)"
  [ -n "$CWD" ] || CWD="$PWD"
  SESSION_ID="$(printf '%s' "$INPUT" | "$JQ" -r '.session_id | strings' 2>/dev/null)"
  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path | strings' 2>/dev/null)"
  CURRENT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
  MESSAGE="$(printf '%s' "$INPUT" | "$JQ" -r '.last_assistant_message // empty' 2>/dev/null | head -c 1500)"
fi
if [ "$HARNESS" = --sweep ]; then
  # launchd must retain a live main process until its sweep finishes.
  locked_worker </dev/null >/dev/null 2>&1
else
  # Network and opportunistic sweep work never hold up the harness.
  ( locked_worker </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
fi
exit 0
