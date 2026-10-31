#!/bin/bash
# Grok Bot turn-end notifier. Harness-agnostic: called from Codex and Claude Code Stop hooks.
# Usage: notify.sh <harness>. Reads hook JSON on stdin. Never prints to stdout, always exits 0.
#
# What it does, in order:
#   1. Finds the git worktree root for the directory the agent ran in.
#   2. Does nothing unless that root contains a .grokbot marker (opt-in per worktree).
#   3. Reads the bot name from the marker and the agent's status from .grokbot-status.
#   4. Loads that bot's webhook URL + auth from ~/.grokbot-hooks/<bot>.env.
#   5. POSTs a small JSON payload in the background, so the harness is never blocked.
HARNESS="${1:-unknown}"
DIR="$HOME/.grokbot-hooks"
LOG="$DIR/notify.log"

# Prefer jq from PATH, fall back to /usr/bin/jq. Hooks often run with a minimal PATH.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"

INPUT="$(cat 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)"
[ -z "$CWD" ] && CWD="$PWD"
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"

# No marker: this is not a bot-launched worktree. Stay silent (log only in debug mode).
if [ ! -f "$ROOT/.grokbot" ]; then
  [ -f "$DIR/debug" ] && echo "$TS $HARNESS no-marker $ROOT" >> "$LOG"
  exit 0
fi

# Bot name is sanitised so it can only ever point at a file inside $DIR.
BOT="$(head -n1 "$ROOT/.grokbot" | tr -cd 'a-z0-9_-')"
STATUS_FILE="$ROOT/.grokbot-status"
STATUS="$( [ -f "$STATUS_FILE" ] && head -c 2000 "$STATUS_FILE" || echo "turn_ended_no_status")"
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
