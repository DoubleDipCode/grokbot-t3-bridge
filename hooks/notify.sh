#!/bin/bash
# Grok Bot turn-end notifier. Harness-agnostic: called from Codex and Claude Code Stop hooks.
# Usage: notify.sh <harness>. Reads hook JSON on stdin. Never prints to stdout, always exits 0.
#
# What it does, in order:
#   1. Finds the git worktree root for the directory the agent ran in.
#   2. If that root has a .grokbot marker: reads the bot name and the agent's status from
#      .grokbot-status, and remembers worktree -> bot in markers.tsv.
#   3. If there is no marker but markers.tsv knows the worktree (it was removed, or the
#      session's cwd points at an old path): still notifies that bot, with worktree_missing.
#   4. Otherwise: logs "no-marker <path>" and stops. Nothing is sent.
#   5. Loads that bot's webhook URL + auth from ~/.grokbot-hooks/<bot>.env.
#   6. POSTs a small JSON payload in the background, so the harness is never blocked.
HARNESS="${1:-unknown}"
DIR="$HOME/.grokbot-hooks"
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

INPUT="$(cat 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)"
[ -z "$CWD" ] && CWD="$PWD"
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"

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
  STATUS="$( [ -f "$STATUS_FILE" ] && head -c 2000 "$STATUS_FILE" || echo "turn_ended_no_status")"
else
  # No marker. If we have seen this worktree before, the marker was removed with the
  # worktree, or the session is still running in an old path. Tell the bot anyway.
  BOT="$(awk -F'\t' -v r="$ROOT" '$1==r {b=$2} END{print b}' "$MAP" 2>/dev/null | tr -cd 'a-z0-9_-')"
  if [ -z "$BOT" ]; then
    # Always logged (no debug flag needed), so a missed callback is visible.
    echo "$TS $HARNESS no-marker $ROOT" >> "$LOG"
    exit 0
  fi
  STATUS="worktree_missing worktree $ROOT no longer has a .grokbot marker (deleted or moved); read the thread for its real state"
fi

BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
# Codex passes last_assistant_message on stdin. Other harnesses may not; then it is empty.
LAST="$(printf '%s' "$INPUT" | "$JQ" -r '.last_assistant_message // empty' 2>/dev/null | head -c 1500)"
echo "$TS $HARNESS bot=$BOT branch=$BRANCH status=$(printf '%s' "$STATUS" | head -n1 | head -c 80)" >> "$LOG"

ENV="$DIR/$BOT.env"
[ -f "$ENV" ] || exit 0
# shellcheck disable=SC1090
. "$ENV"   # sets GROKBOT_WEBHOOK_URL and GROKBOT_WEBHOOK_AUTH
[ -n "$GROKBOT_WEBHOOK_URL" ] || exit 0

# shellcheck disable=SC2016  # $vars below are jq variables, not shell
BODY="$("$JQ" -n --arg bot "$BOT" --arg harness "$HARNESS" --arg worktree "$ROOT" \
  --arg branch "$BRANCH" --arg status "$STATUS" --arg last "$LAST" --arg ts "$TS" \
  '{event:"t3_turn_ended",bot:$bot,harness:$harness,worktree:$worktree,branch:$branch,status:$status,last_message:$last,ended_at:$ts}')"

# Fire and forget in a detached subshell. Only the HTTP status code is logged, never the auth.
( curl -sS -m 10 -X POST "$GROKBOT_WEBHOOK_URL" -H 'Content-Type: application/json' \
    ${GROKBOT_WEBHOOK_AUTH:+-H "Authorization: $GROKBOT_WEBHOOK_AUTH"} \
    --data "$BODY" -o /dev/null -w "$TS $BOT webhook http=%{http_code}\n" >> "$LOG" 2>&1 & ) >/dev/null 2>&1
exit 0
