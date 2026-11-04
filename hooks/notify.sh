#!/bin/bash
# shellcheck disable=SC2016 # Single-quoted expressions are jq programs.
# Actionable Stop notifications, approval-prompt pings (claude-notify, codex-permission)
# and --sweep, which checks saved waiting worktrees and stalled running harnesses.
HARNESS="${1:-unknown}"
DIR="${GROKBOT_HOOKS_DIR:-$HOME/.grokbot-hooks}"
STATE="${GROKBOT_STATE_DIR:-$DIR/state}"
STALE="${GROKBOT_STALE_SECONDS:-7200}"
case "$STALE" in *[!0-9]*|'') STALE=7200 ;; esac
STALL_MIN="${GROKBOT_STALL_MINUTES:-45}"
case "$STALL_MIN" in *[!0-9]*|''|0) STALL_MIN=45 ;; esac
HARNESS_RE="${GROKBOT_HARNESS_RE:-^(claude|codex)\$}"   # process names that count as a running harness
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

# post: POST the payload built from the globals BOT ROOT HARNESS BRANCH STATUS LAST TS SESSION
# TRANSCRIPT SESSION_CWD. Returns 0 on HTTP 2xx, 1 on failure, 2 when the bot has no webhook.
post() {
  local env="$DIR/$BOT.env" body http result
  [ -f "$env" ] || return 2
  GROKBOT_WEBHOOK_URL=
  GROKBOT_WEBHOOK_AUTH=
  # shellcheck disable=SC1090
  . "$env"
  [ -n "$GROKBOT_WEBHOOK_URL" ] || return 2
  body="$("$JQ" -n --arg bot "$BOT" --arg harness "$HARNESS" --arg worktree "$ROOT" \
    --arg branch "$BRANCH" --arg status "$STATUS" --arg last "$LAST" --arg ts "$TS" \
    --arg session "$SESSION" --arg transcript "$TRANSCRIPT" --arg cwd "$SESSION_CWD" \
    '{event:"t3_turn_ended",bot:$bot,harness:$harness,worktree:$worktree,branch:$branch,status:$status,last_message:$last,ended_at:$ts,cwd:$cwd,session_id:$session,transcript_path:$transcript}')" || return 1
  # Never log curl diagnostics: they can contain a secret URL.
  http="$(curl -sS -m 10 -X POST "$GROKBOT_WEBHOOK_URL" -H 'Content-Type: application/json' \
    ${GROKBOT_WEBHOOK_AUTH:+-H "Authorization: $GROKBOT_WEBHOOK_AUTH"} \
    --data "$body" -o /dev/null -w '%{http_code}' 2>/dev/null)"
  result=$?
  echo "$TS $BOT webhook http=$http result=$result" >> "$LOG"
  [ "$result" -eq 0 ] && [[ "$http" = 2?? ]]
}

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
SAVED_TRANSCRIPT="$("$JQ" -r '.transcript // empty' "$CACHE" 2>/dev/null)"
CLOCK="$("$JQ" -r '.clock // empty' "$CACHE" 2>/dev/null)"
case "$CLOCK" in *[!0-9]*|'') CLOCK="$NOW"; NOCLOCK=1 ;; *) NOCLOCK= ;; esac
if [ "$WORD" = waiting ]; then
  if [ ! -f "$CACHE" ]; then
    "$JQ" -n --argjson clock "$NOW" '{clock:$clock}' > "$CACHE"
  elif [ -n "$NOCLOCK" ]; then
    # A stall marker may have created the cache without a clock; start the waiting clock now.
    "$JQ" --argjson clock "$NOW" '. + {clock:$clock}' "$CACHE" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
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
post
RC=$?
if [ "$RC" -eq 0 ]; then
  "$JQ" -n --arg status "$STATUS" --arg transcript "${TRANSCRIPT:-$SAVED_TRANSCRIPT}" --argjson clock "$(date +%s)" \
    '{status:$status,clock:$clock,transcript:$transcript}' > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
fi
}

# Lazily list the working directories of running harness processes (claude, codex).
# Empty when ps or lsof is unavailable, which disables the stall check rather than guessing.
load_harness_cwds() {
  [ -z "${HCWDS_LOADED:-}" ] || return 0
  HCWDS_LOADED=1
  HCWDS=
  local pids lsof
  pids="$(ps -axo pid=,comm= 2>/dev/null | awk -v re="$HARNESS_RE" \
    '{p=$1; $1=""; sub(/^ +/,""); n=split($0,a,"/"); if (a[n] ~ re) printf "%s%s", (c++ ? "," : ""), p}')"
  [ -n "$pids" ] || return 0
  lsof="$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)"
  HCWDS="$("$lsof" -a -d cwd -Fn -p "$pids" 2>/dev/null | sed -n 's/^n//p')"
}

harness_running_in() {
  load_harness_cwds
  [ -n "$HCWDS" ] || return 1
  printf '%s\n' "$HCWDS" | awk -v r="$1" '$0==r || index($0, r "/")==1 {f=1} END{exit !f}'
}

# Succeeds when there is any sign of life newer than GROKBOT_STALL_MINUTES in a worktree.
recently_active() {
  local path="$1" gitdir slug d
  # Files in the worktree, ignoring .git and node_modules. Build outputs count as activity.
  [ -n "$(find "$path" \( -name .git -o -name node_modules \) -prune -o -type f -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ] && return 0
  # Git metadata: commits, staging and checkouts touch these and nothing in the tree.
  gitdir="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$gitdir" ] && [ -n "$(find "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD" -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  # Session transcript: the path saved by the last Stop ping, and Claude's per-directory
  # project logs. These keep changing during a long agent turn even with no file edits.
  slug="$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/-/g')"
  for d in "$HOME"/.claude/projects/"$slug" "$HOME"/.claude-*/projects/"$slug"; do
    [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 1 -name '*.jsonl' -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ] && return 0
  done
  local saved
  saved="$("$JQ" -r '.transcript // empty' "$STATE/$(printf '%s' "$path" | shasum -a 256 | awk '{print $1}').json" 2>/dev/null)"
  if [ -n "$saved" ] && [ -f "$saved" ] && [ -n "$(find "$saved" -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# A harness is running in a marked worktree, its last status was not a finished one, and
# nothing has changed for GROKBOT_STALL_MINUTES: it may be blocked on an approval prompt.
# One ping per stall: the status file's mtime identifies the stall, and any later activity
# clears the flag, so a second stall in the same worktree pings again.
stall_check() {
  local path="$1" status_file="$1/.grokbot-status" word mtime cache
  word="$(awk 'NR==1 {print $1; exit}' "$status_file" 2>/dev/null)"
  case "$word" in
    # Finished or already actionable statuses were pinged at turn end, and waiting has its own
    # stale timer. An open idle session with one of these is normal, not a stall.
    done|failed|needs_input|idle|waiting) return 0 ;;
  esac
  harness_running_in "$path" || return 0
  cache="$STATE/$(printf '%s' "$path" | shasum -a 256 | awk '{print $1}').json"
  if recently_active "$path"; then
    if "$JQ" -e 'has("stall_status_mtime")' "$cache" >/dev/null 2>&1; then
      "$JQ" 'del(.stall_status_mtime)' "$cache" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
    fi
    return 0
  fi
  mtime="$(stat -c %Y "$status_file" 2>/dev/null || stat -f %m "$status_file" 2>/dev/null || echo 0)"
  if "$JQ" -e --argjson m "$mtime" '.stall_status_mtime == $m' "$cache" >/dev/null 2>&1; then
    return 0  # already pinged for this stall
  fi
  # The bot comes from the marker itself, as in process().
  BOT="$(head -n1 "$path/.grokbot" 2>/dev/null | tr -cd 'a-z0-9_-')"
  [ -n "$BOT" ] || return 0
  ROOT="$path"
  HARNESS=sweep
  SESSION=
  TRANSCRIPT=
  SESSION_CWD=
  LAST=
  TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  BRANCH="$(git -C "$path" branch --show-current 2>/dev/null)"
  # N is the threshold: every probe was quiet for at least that long. Sweeps run every
  # few minutes, so the real figure is within one sweep interval of it.
  STATUS="stalled ${STALL_MIN}m approval? $( { [ -f "$status_file" ] && head -c 1900 "$status_file" || printf turn_ended_no_status; } )"
  echo "$TS sweep bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -n1 | head -c 80)" >> "$LOG"
  if post; then
    { "$JQ" --argjson m "$mtime" '. + {stall_status_mtime:$m}' "$cache" 2>/dev/null ||
      "$JQ" -n --argjson m "$mtime" '{stall_status_mtime:$m}'; } > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
  fi
}

sweep() {
  # Waiting and missing markers need periodic attention; do not replay done.
  # A running harness whose worktree has gone quiet gets a stall check.
  while IFS=$'\t' read -r path bot; do
    [ -n "$path" ] && [ -n "$bot" ] || continue
    [ "$path" = "$CURRENT" ] && continue
    if [ ! -f "$path/.grokbot" ] ||
      [ "$(awk 'NR==1 {print $1; exit}' "$path/.grokbot-status" 2>/dev/null)" = waiting ]; then
      process "$path" sweep ""
    elif [ -d "$path" ]; then
      stall_check "$path" "$bot"
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

# Approval prompts: claude-notify (Claude Code Notification) and codex-permission (Codex
# PermissionRequest). Always ping, never dedupe, never touch .grokbot-status or the dedupe
# cache. Runs without the sweep lock so the ping is not queued behind a sweep.
approval_summary() {
  # Sets SUMMARY (one line, 200 bytes at most) and MESSAGE. Returns 1 for notifications that
  # are not about approval or input, which are ignored.
  local type tool detail
  case "$HARNESS" in
    claude-notify)
      type="$(printf '%s' "$INPUT" | "$JQ" -r '.notification_type | strings' 2>/dev/null)"
      MESSAGE="$(printf '%s' "$INPUT" | "$JQ" -r '.message | strings' 2>/dev/null | head -c 1500)"
      case "$type" in
        permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input) ;;
        '') # Older versions send no type: only the permission message is about approval.
          case "$MESSAGE" in *[Pp]ermission*) ;; *) return 1 ;; esac ;;
        *) return 1 ;;  # idle_prompt (turn-end pings cover it), auth_success, quota_*, ...
      esac
      # Best effort: the notification text names the tool, the transcript has the command.
      if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        detail="$(tail -n 15 "$TRANSCRIPT_PATH" 2>/dev/null | "$JQ" -rR 'fromjson? | select(.type=="assistant")
          | .message.content[]? | select(.type=="tool_use")
          | "\(.name): \(.input.command // .input.description // .input.file_path // .input.url // "")"' 2>/dev/null | tail -n 1)"
      fi
      SUMMARY="${detail:-$MESSAGE}"
      ;;
    codex-permission)
      tool="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name | strings' 2>/dev/null)"
      detail="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input | if type=="object" then (.description // .command // "" | if type=="array" then join(" ") else tostring end) else "" end' 2>/dev/null)"
      MESSAGE="$tool${detail:+: $detail}"
      SUMMARY="$MESSAGE"
      ;;
  esac
  SUMMARY="$(printf '%s' "$SUMMARY" | tr '\n\r\t' '   ' | head -c 200)"
  [ -n "$SUMMARY" ] || SUMMARY="(no details)"
}

approval() {
  local d top root bot
  approval_summary || exit 0
  d="$(cd "$CWD" 2>/dev/null && pwd -P || echo "$CWD")"
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || echo "$d")"
  root=
  while :; do
    [ -f "$d/.grokbot" ] && { root="$d"; break; }
    [ "$d" = "$top" ] || [ "$d" = / ] || [ "$d" = . ] && break
    d="$(dirname "$d")"
  done
  TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  if [ -n "$root" ]; then
    bot="$(head -n1 "$root/.grokbot" | tr -cd 'a-z0-9_-')"
  else
    # Marker removed with the worktree: fall back to the marker map, as Stop does.
    root="$top"
    bot="$(awk -F'\t' -v r="$root" '$1==r {b=$2} END{print b}' "$MAP" 2>/dev/null | tr -cd 'a-z0-9_-')"
  fi
  if [ -z "$bot" ]; then
    echo "$TS $HARNESS no-marker $top" >> "$LOG"
    exit 0
  fi
  BOT="$bot"
  ROOT="$root"
  SESSION="$SESSION_ID"
  TRANSCRIPT="$TRANSCRIPT_PATH"
  SESSION_CWD="$CWD"
  LAST="$MESSAGE"
  BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
  STATUS="needs_input approval $SUMMARY"
  echo "$TS $HARNESS bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -c 80)" >> "$LOG"
  ( post </dev/null >/dev/null 2>&1; echo "$(date '+%Y-%m-%dT%H:%M:%S%z') worker-complete" >> "$LOG" ) &
  wait
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
  case "$HARNESS" in
    claude-notify|codex-permission)
      # Background everything, including the filtering, so the harness never waits on us.
      ( approval </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
      exit 0 ;;
  esac
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
