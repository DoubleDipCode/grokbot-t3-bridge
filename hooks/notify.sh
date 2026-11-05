#!/bin/bash
# shellcheck disable=SC2016 # Single-quoted expressions are jq programs.
# Actionable Stop notifications, approval-prompt pings (claude-notify, codex-permission),
# turn-start bookkeeping (claude-start, codex-start; sends nothing) and --sweep, which checks saved
# worktrees for stalls (a dead turn, no harness, or a running harness gone quiet).
HARNESS="${1:-unknown}"
DIR="${GROKBOT_HOOKS_DIR:-$HOME/.grokbot-hooks}"
[ -d "$DIR" ] || exit 0  # not installed
# Optional local config ($DIR/config, KEY=value lines, parsed and never sourced). Real environment
# variables win over it. Also read for --sweep under launchd, which has no shell profile.
# config-lib.sh is installed next to this script; without it only environment variables apply.
# shellcheck source=hooks/config-lib.sh
[ ! -f "$DIR/config-lib.sh" ] || { . "$DIR/config-lib.sh" && grokbot_load_config "$DIR/config"; } || true
STATE="${GROKBOT_STATE_DIR:-$DIR/state}"
STALE="${GROKBOT_STALE_SECONDS:-7200}"
case "$STALE" in *[!0-9]*|'') STALE=7200 ;; esac
STALL_MINUTES="${GROKBOT_STALL_MINUTES:-45}"
case "$STALL_MINUTES" in *[!0-9]*|'') STALL_MINUTES=45 ;; esac
LOG="$DIR/notify.log"
MAP="$DIR/markers.tsv"   # worktree<TAB>bot, so a removed or switched worktree can still be reported
umask 077                # anything this script creates (log, map) is private to the user
# launchd's PATH has no /usr/sbin, where macOS keeps lsof. Without it harness_running cannot
# tell and the sweep silently skips every stall ping while a harness process exists.
PATH="$PATH:/usr/sbin:/sbin"

# Thread id from the harness environment: T3 sets T3CODE_THREAD_ID for Claude Code sessions. The
# sweep workers inherit it from the hook that started them, so only the current worktree may use it.
REG_ENV_THREAD="${T3CODE_THREAD_ID:-}"

# Prefer jq from PATH, fall back to /usr/bin/jq. Hooks often run with a minimal PATH.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"

# Thread registry (threads.sqlite). Optional: without registry-lib.sh next to this script the
# payload simply has no thread fields. Every registry call is best effort and never blocks a ping.
# shellcheck source=hooks/registry-lib.sh
if [ -f "$DIR/registry-lib.sh" ]; then
  . "$DIR/registry-lib.sh" || true
fi
if ! type registry_record >/dev/null 2>&1; then
  registry_record() { :; }; registry_resolve() { :; }; registry_refresh() { :; }
  registry_load_thread() { THREAD_ID=; THREAD_TITLE=; PROJECT_ID=; THREAD_SOURCE=; }
  registry_summary() { SUMMARY_JSON='[]'; SUMMARY_MORE=0; }
fi

# Keep the log bounded: one rotation at about 1 MB. no-marker lines are logged on every
# turn of your own sessions too, so this stops them piling up forever.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

# post: POST the payload built from the globals BOT ROOT HARNESS BRANCH STATUS LAST TS SESSION
# TRANSCRIPT SESSION_CWD, plus the registry's thread fields. Returns 0 on HTTP 2xx, 1 on failure, 2 when the bot has no webhook.
post() {
  local env="$DIR/$BOT.env" body http result
  [ -f "$env" ] || return 2
  GROKBOT_WEBHOOK_URL=
  GROKBOT_WEBHOOK_AUTH=
  # shellcheck disable=SC1090
  . "$env"
  [ -n "$GROKBOT_WEBHOOK_URL" ] || return 2
  registry_load_thread "$ROOT"
  registry_summary "$BOT"
  body="$("$JQ" -n --arg bot "$BOT" --arg harness "$HARNESS" --arg worktree "$ROOT" \
    --arg branch "$BRANCH" --arg status "$STATUS" --arg last "$LAST" --arg ts "$TS" \
    --arg session "$SESSION" --arg transcript "$TRANSCRIPT" --arg cwd "$SESSION_CWD" \
    --arg thread_id "${THREAD_ID:-}" --arg thread_title "${THREAD_TITLE:-}" --arg project_id "${PROJECT_ID:-}" \
    --arg thread_source "${THREAD_SOURCE:-}" --argjson open_threads "${SUMMARY_JSON:-[]}" --argjson open_more "${SUMMARY_MORE:-0}" \
    '{event:"t3_turn_ended",bot:$bot,harness:$harness,worktree:$worktree,branch:$branch,status:$status,last_message:$last,ended_at:$ts,cwd:$cwd,session_id:$session,transcript_path:$transcript,thread_id:$thread_id,thread_title:$thread_title,project_id:$project_id,thread_source:$thread_source,my_open_threads:$open_threads,my_open_threads_more:$open_more}')" || return 1
  # Record stall attempts only once a payload and webhook are available.
  # At most one request per revision, even on HTTP failure or worker crash.
  if [ "$HARNESS" = sweep ] && [[ "$STATUS" = stalled\ * ]]; then
    touch "$STATE/$KEY.stalled" || return 1
    # A dead turn is reported once per turn start, whatever happens to the status file.
    [ -z "${TURN_DEAD:-}" ] || write_epoch "$STATE/$KEY.turndead" "$TURN_START" || return 1
  fi
  # Never log curl diagnostics: they can contain a secret URL.
  http="$(curl -sS -m 10 -X POST "$GROKBOT_WEBHOOK_URL" -H 'Content-Type: application/json' \
    ${GROKBOT_WEBHOOK_AUTH:+-H "Authorization: $GROKBOT_WEBHOOK_AUTH"} \
    --data "$body" -o /dev/null -w '%{http_code}' 2>/dev/null)"
  result=$?
  echo "$TS $BOT webhook http=$http result=$result" >> "$LOG"
  [ "$result" -eq 0 ] && [[ "$http" = 2?? ]]
}

# write_epoch <file> <number>: atomic one-line write.
write_epoch() {
  printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

state_key() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# Turn bookkeeping, one pair of files per worktree in $STATE (epoch seconds):
#   <key>.turn_started  written by the turn-start hook (UserPromptSubmit)
#   <key>.turn_ended    written by the Stop hook
# A turn is open when it started at or after the last end (ties count as open: a queued message can
# start in the same second the previous turn ended). turn_open <key> sets TURN_START.
turn_open() {
  local s e
  s="$(cat "$STATE/$1.turn_started" 2>/dev/null)"
  e="$(cat "$STATE/$1.turn_ended" 2>/dev/null)"
  case "$s" in *[!0-9]*|'') return 1 ;; esac
  case "$e" in *[!0-9]*|'') e=0 ;; esac
  [ "$s" -ge "$e" ] || return 1
  TURN_START="$s"
}

# A T3 worktree: the harness has T3CODE_THREAD_ID, or the path is under T3's worktrees directory.
is_t3_worktree() {
  [ -z "$REG_ENV_THREAD" ] || return 0
  case "$1" in "${T3CODE_HOME:-$HOME/.t3}/worktrees/"*) return 0 ;; esac
  return 1
}

# ensure_marker <worktree> <bot>: record or refresh worktree -> bot. Exact match on the path column,
# one line per worktree, newest last, capped at 500 entries. Skipped when the line is already there.
ensure_marker() {
  local root="$1" bot="$2" tmp
  if [ -n "$bot" ] && ! awk -F'\t' -v r="$root" -v b="$bot" '$1==r && $2==b {f=1} END{exit !f}' "$MAP" 2>/dev/null; then
    tmp="$(mktemp "$DIR/markers.XXXXXX" 2>/dev/null)" && {
      { awk -F'\t' -v r="$root" '$1!=r' "$MAP" 2>/dev/null; printf '%s\t%s\n' "$root" "$bot"; } | tail -n 500 > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$MAP"
      rm -f "$tmp" 2>/dev/null
    }
  fi
}

# A live harness is conservative evidence of an active turn, including tool/CI
# waits. Match executable names in argv, not arbitrary mentions of "codex".
# lsof is restricted to candidate PIDs and cwd, so no recursive file scan.
# Returns 0 when one runs in the worktree, 1 when none does, 2 when it cannot tell.
harness_running() {
  local pids result cwd root
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 2
  pids="$(pgrep -f '(^|/|[[:space:]])(codex|claude|claude-code|agent-harness)([[:space:]]|$)' 2>/dev/null)"
  result=$?
  [ "$result" -eq 1 ] && return 1
  [ "$result" -eq 0 ] || return 2
  pids="$(printf '%s' "$pids" | paste -sd, -)"
  cwd="$(lsof -a -p "$pids" -d cwd -Fn 2>/dev/null)" || return 2
  while IFS= read -r line; do
    case "$line" in
      "n$root"|"n$root/"*) return 0 ;;
    esac
  done <<< "$cwd"
  return 1
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
  ensure_marker "$ROOT" "$BOT"
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
# Registry first, so it is current even when this turn is not sent (waiting, duplicate). Sweeps
# only update rows they already know; the thread id of other worktrees never comes from our env.
if [ "$HARNESS" = sweep ]; then
  registry_record sweep
else
  START_BEFORE="${GROKBOT_HOOK_EPOCH:-}"
  registry_record turn
  registry_resolve "$ROOT" "$REG_ENV_THREAD"
fi
SAVED_TRANSCRIPT="$("$JQ" -r '.transcript // empty' "$CACHE" 2>/dev/null)"
# Keep the newest transcript path even when this Stop is not sent (dedupe, waiting): the stall
# check uses it, and a new session in the same worktree must replace the old one's path.
if [ -n "$TRANSCRIPT" ] && [ "$TRANSCRIPT" != "$SAVED_TRANSCRIPT" ] && [ -f "$CACHE" ]; then
  "$JQ" --arg t "$TRANSCRIPT" '. + {transcript:$t}' "$CACHE" > "$CACHE.tmp" 2>/dev/null && mv -f "$CACHE.tmp" "$CACHE"
  SAVED_TRANSCRIPT="$TRANSCRIPT"
fi
CLOCK="$("$JQ" -r '.clock // empty' "$CACHE" 2>/dev/null)"
case "$CLOCK" in *[!0-9]*|'') CLOCK="$NOW"; NOCLOCK=1 ;; *) NOCLOCK= ;; esac
# Track file changes separately from delivery state. Include high-resolution mtime
# and inode so rewriting the same line also starts a new stall period.
REVISION="$(perl -MTime::HiRes=stat -e '
  my @s = stat($ARGV[0]); print @s ? join(":", @s[1,7,9]) : "missing";
' "$ROOT/.grokbot-status")"
OBSERVED="$STATE/$KEY.observed"
if ! "$JQ" -e --arg revision "$REVISION" --arg status "$STATUS"   '.revision == $revision and .status == $status' "$OBSERVED" >/dev/null 2>&1; then
  "$JQ" -n --arg revision "$REVISION" --arg status "$STATUS"     '{revision:$revision,status:$status}' > "$OBSERVED.tmp" &&
    mv -f "$OBSERVED.tmp" "$OBSERVED"
  rm -f "$STATE/$KEY.stalled" "$STATE/$KEY.waiting"
fi
# Dead turn: the turn-start hook recorded a turn that never reported its end (no Stop), and no
# harness is left in the worktree. This beats the status word below, so a follow-up turn on a
# `done` or `waiting` thread that died is reported too. With a harness still running the usual
# rules below apply (approval? ping, waiting reminder, done is skipped).
TURN_DEAD=
if [ "$HARNESS" = sweep ] && [ -f "$ROOT/.grokbot" ] && turn_open "$KEY"; then
  # Once per dead turn, however the status file changes afterwards.
  [ "$(cat "$STATE/$KEY.turndead" 2>/dev/null)" != "$TURN_START" ] || return 0
  # Quiet since the later of the turn start and the last status write.
  LIVE="$(perl -e 'my $m = (stat($ARGV[0]))[9] || 0; print $m > $ARGV[1] ? $m : $ARGV[1]' "$ROOT/.grokbot-status" "$TURN_START")"
  AGE=$((NOW - LIVE))
  [ "$AGE" -ge "$((STALL_MINUTES * 60))" ] || return 0
  harness_running "$ROOT"
  case $? in
    1) TURN_DEAD=1
       [ -f "$ROOT/.grokbot-status" ] || STATUS=no_status
       STATUS="stalled $((AGE / 60))m turn_died $STATUS"
       WORD=stalled ;;
    2) return 0 ;;  # pgrep or lsof failed: prefer a missed alert to a false one
  esac
fi
if [ -n "$TURN_DEAD" ]; then
  : # STATUS is final
elif [ "$WORD" = waiting ]; then
  [ ! -f "$STATE/$KEY.waiting" ] || return 0
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
elif [ "$HARNESS" = sweep ] && [ -f "$ROOT/.grokbot" ]; then
  [ "$WORD" != "done" ] || return 0
  if [ -f "$STATE/$KEY.stalled" ]; then
    # Already pinged for this status revision. New activity from a running harness ends that
    # stall, so a later one (another prompt, same status text) pings again.
    if harness_running "$ROOT" && recently_active "$ROOT"; then rm -f "$STATE/$KEY.stalled"; fi
    return 0
  fi
  MODIFIED="$(perl -e 'print((stat($ARGV[0]))[9] || (stat($ARGV[1]))[9] || time)'     "$ROOT/.grokbot-status" "$ROOT/.grokbot")"
  # No previous ping means the file timestamp alone determines age.
  if [ ! -f "$CACHE" ]; then CLOCK="$MODIFIED"; fi
  [ "$MODIFIED" -le "$CLOCK" ] || CLOCK="$MODIFIED"
  AGE=$((NOW - CLOCK))
  [ "$AGE" -ge "$((STALL_MINUTES * 60))" ] || return 0
  harness_running "$ROOT"
  case $? in
    0)
      # A harness is alive, so this may be a turn blocked on an approval prompt that no hook
      # reported. Finished or already actionable statuses are an idle open session, not a stall.
      case "$WORD" in failed|needs_input|idle) return 0 ;; esac
      # Long builds and quiet turns: any recent file, git, or session-log activity means working.
      ! recently_active "$ROOT" || return 0
      # AGE is measured from the status file or last ping, so it can overstate the quiet time;
      # every activity probe was quiet for at least GROKBOT_STALL_MINUTES, so report that.
      STATUS="stalled ${STALL_MINUTES}m approval? $STATUS" ;;
    1) STATUS="stalled $((AGE / 60))m $STATUS" ;;
    *) return 0 ;;  # pgrep or lsof failed: prefer a missed alert to a false one
  esac
elif [ "$WORD" != needs_input ] && [ "$WORD" != failed ] &&
  "$JQ" -e --arg status "$STATUS" '.status == $status' "$CACHE" >/dev/null 2>&1; then
  echo "$TS $HARNESS skip=duplicate $ROOT" >> "$LOG"
  return 0
fi

BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
echo "$TS $HARNESS bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -n1 | head -c 80)" >> "$LOG"
post
RC=$?
[ -z "$TURN_DEAD" ] || [ "$RC" -eq 2 ] || registry_mark_stalled "${STATUS#stalled * }"
if [ "$RC" -eq 0 ]; then
  [ "$WORD" != waiting ] || touch "$STATE/$KEY.waiting"
  "$JQ" -n --arg status "$STATUS" --arg transcript "${TRANSCRIPT:-$SAVED_TRANSCRIPT}" --argjson clock "$(date +%s)" \
    '{status:$status,clock:$clock,transcript:$transcript}' > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
fi
}

# Succeeds when there is any sign of life newer than GROKBOT_STALL_MINUTES in a worktree.
recently_active() {
  local path="$1" gitdir slug d
  # Files in the worktree, ignoring .git and node_modules. Build outputs count as activity.
  [ -n "$(find "$path" \( -name .git -o -name node_modules \) -prune -o -type f -mmin "-$STALL_MINUTES" -print -quit 2>/dev/null)" ] && return 0
  # Git metadata: commits, staging and checkouts touch these and nothing in the tree.
  gitdir="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$gitdir" ] && [ -n "$(find "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD" -mmin "-$STALL_MINUTES" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  # Session transcript: the path saved by the last Stop ping, and Claude's per-directory
  # project logs. These keep changing during a long agent turn even with no file edits.
  slug="$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/-/g')"
  # Also the dirs named by GROKBOT_CLAUDE_DIRS / GROKBOT_EXTRA_CLAUDE_DIRS / CLAUDE_CONFIG_DIR.
  local extra=() p dirs=()
  IFS=: read -r -a extra <<< "${GROKBOT_CLAUDE_DIRS:-}:${GROKBOT_EXTRA_CLAUDE_DIRS:-}:${CLAUDE_CONFIG_DIR:-}"
  dirs=("$HOME/.claude/projects/$slug" "$HOME"/.claude-*/projects/"$slug")
  for p in ${extra[@]+"${extra[@]}"}; do
    [ -z "$p" ] || dirs+=("${p%/}/projects/$slug")
  done
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 1 -name '*.jsonl' -mmin "-$STALL_MINUTES" -print -quit 2>/dev/null)" ] && return 0
  done
  local saved
  saved="$("$JQ" -r '.transcript // empty' "$STATE/$(printf '%s' "$path" | shasum -a 256 | awk '{print $1}').json" 2>/dev/null)"
  if [ -n "$saved" ] && [ -f "$saved" ] && [ -n "$(find "$saved" -mmin "-$STALL_MINUTES" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# Turn start (claude-start, codex-start). Runs under the sweep lock: marker map, thread registry.
# Needs START_EPOCH, the time the hook fired. Sends nothing.
start_turn() {
  ROOT="$1"
  HARNESS="$2"
  SESSION="${3:-}"
  LAST=
  TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  [ -f "$ROOT/.grokbot" ] || return 0
  BOT="$(head -n1 "$ROOT/.grokbot" | tr -cd 'a-z0-9_-')"
  [ -n "$BOT" ] || return 0
  ensure_marker "$ROOT" "$BOT"
  STATUS=running
  WORD=running
  registry_record start
  registry_resolve "$ROOT" "${4:-}"
}

# Turn starts seen before the worktree had a .grokbot marker (a thread writes it with its first
# command, after its first prompt). $STATE/pending/<key> holds: worktree, epoch, thread id, harness,
# session id. Once the marker exists the start is adopted as if the hook had seen it; if the turn
# has already ended meanwhile (Stop writes turn_ended) it is just dropped. Unclaimed ones expire.
adopt_pending() {
  local f root epoch tid harness session key end NOW_P
  NOW_P="$(date +%s)"
  [ -d "$STATE/pending" ] || return 0
  for f in "$STATE"/pending/*; do
    [ -f "$f" ] || continue
    { IFS= read -r root; IFS= read -r epoch; IFS= read -r tid; IFS= read -r harness; IFS= read -r session; } < "$f" || true
    case "$epoch" in *[!0-9]*|'') rm -f "$f"; continue ;; esac
    if [ -n "$root" ] && [ -f "$root/.grokbot" ]; then
      key="$(state_key "$root")"
      end="$(cat "$STATE/$key.turn_ended" 2>/dev/null)"
      case "$end" in *[!0-9]*|'') end=0 ;; esac
      if [ "$end" -lt "$epoch" ]; then
        write_epoch "$STATE/$key.turn_started" "$epoch"
        START_EPOCH="$epoch"
        start_turn "$root" "${harness:-claude-start}" "$session" "$tid"
      fi
      rm -f "$f"
    elif [ ! -d "$root" ] || [ "$((NOW_P - epoch))" -gt 86400 ]; then
      rm -f "$f"
    fi
  done
}

sweep() {
  # Check all known worktrees; process preserves missing-marker delivery.
  while IFS=$'\t' read -r path bot; do
    [ -n "$path" ] && [ -n "$bot" ] || continue
    [ "$path" = "$CURRENT" ] && continue
    process "$path" sweep ""
  done < "$MAP"
}

worker() {
  local mode="$HARNESS"   # process() overwrites HARNESS, so remember whether this is the launchd sweep
  case "$mode" in
    claude-start|codex-start)
      # Bookkeeping only: no sweep, no registry upkeep, so a prompt never waits on more than this.
      START_EPOCH="${GROKBOT_HOOK_EPOCH:-}"
      start_turn "$CURRENT" "$mode" "$SESSION_ID" "$REG_ENV_THREAD"
      echo "$(date '+%Y-%m-%dT%H:%M:%S%z') worker-complete" >> "$LOG"
      return 0 ;;
  esac
  adopt_pending
  [ -z "$CURRENT" ] || process "$CURRENT" "$HARNESS" "$MESSAGE" "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD"
  [ ! -f "$MAP" ] || sweep
  # Registry upkeep (look up missing thread ids, re-check old rows, prune). Small batches per hook,
  # bigger ones for the launchd sweep. Skipped when nothing was ever recorded.
  if [ -f "$REG_DB" ] || [ -f "$MAP" ]; then
    if [ "$mode" = --sweep ]; then registry_refresh full; else registry_refresh; fi
  fi
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
  # Registry: keep the thread row current, using the status file as it is (this ping does not
  # change it). A first event for a worktree may be an approval prompt, so this can create the row.
  STATUS="$( { [ -f "$ROOT/.grokbot-status" ] && head -c 2000 "$ROOT/.grokbot-status" || printf turn_ended_no_status; }; printf '.')"
  STATUS="${STATUS%.}"
  WORD="$(printf '%s' "$STATUS" | awk 'NR==1 {print $1}')"
  registry_record approval
  registry_resolve "$ROOT" "$REG_ENV_THREAD"
  BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
  STATUS="needs_input approval $SUMMARY"
  echo "$TS $HARNESS bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -c 80)" >> "$LOG"
  ( post </dev/null >/dev/null 2>&1; echo "$(date '+%Y-%m-%dT%H:%M:%S%z') worker-complete" >> "$LOG" ) &
  wait
}

# Turn-start and turn-end hooks, synchronous part: two tiny file writes with the time the hook fired,
# so the order of start and end never depends on how long the (locked, backgrounded) worker waits.
# hook_turn_start returns 1 when the worker has nothing to do.
hook_turn_start() {
  local key
  mkdir -p "$STATE" 2>/dev/null || return 1
  key="$(state_key "$CURRENT")"
  if [ -f "$CURRENT/.grokbot" ]; then
    write_epoch "$STATE/$key.turn_started" "$GROKBOT_HOOK_EPOCH" || return 1
    rm -f "$STATE/pending/$key"
    return 0
  fi
  # No marker yet. A thread writes .grokbot with its first command, after its first prompt, so
  # remember the start for T3 worktrees only; the next sweep adopts it once the marker exists.
  is_t3_worktree "$CURRENT" || return 1
  mkdir -p "$STATE/pending" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n%s\n%s\n' "$CURRENT" "$GROKBOT_HOOK_EPOCH" "$REG_ENV_THREAD" "$HARNESS" "$SESSION_ID" \
    > "$STATE/$key.pending.$$" && mv -f "$STATE/$key.pending.$$" "$STATE/pending/$key"
  return 1
}

hook_turn_end() {
  local key
  [ -f "$CURRENT/.grokbot" ] || [ -d "$STATE/pending" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  key="$(state_key "$CURRENT")"
  [ ! -f "$CURRENT/.grokbot" ] || write_epoch "$STATE/$key.turn_ended" "$GROKBOT_HOOK_EPOCH"
  rm -f "$STATE/pending/$key"
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
  GROKBOT_HOOK_EPOCH="$(date +%s)"
  export GROKBOT_HOOK_EPOCH
  case "$HARNESS" in
    claude-start|codex-start) hook_turn_start || exit 0 ;;
    *) hook_turn_end ;;
  esac
fi
if [ "$HARNESS" = --sweep ]; then
  # launchd must retain a live main process until its sweep finishes.
  locked_worker </dev/null >/dev/null 2>&1
else
  # Network and opportunistic sweep work never hold up the harness.
  ( locked_worker </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
fi
exit 0
