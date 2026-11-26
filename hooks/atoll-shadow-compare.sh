#!/bin/bash
# shellcheck disable=SC2016 # Single-quoted expressions are jq programs.
# Compare the direct pings in notify.log with what Atoll recorded for one bot.
# Usage: atoll-shadow-compare.sh <bot> <since, UTC like 2026-01-31T00:00:00Z>
BOT="$(printf '%s' "${1:-}" | tr -cd 'a-z0-9_-')"
SINCE="${2:-}"
case "$SINCE" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) SINCE= ;; esac
[ -n "$BOT" ] && [ -n "$SINCE" ] || { echo "usage: $0 <bot> <since like 2026-01-31T00:00:00Z>" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${GROKBOT_HOOKS_DIR:-$HOME/.grokbot-hooks}"
LOG="$DIR/notify.log"
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
umask 077
# shellcheck source=hooks/config-lib.sh
. "$HERE/config-lib.sh" && grokbot_load_config "$DIR/config"
# shellcheck source=hooks/atoll-lib.sh
. "$HERE/atoll-lib.sh"
[ -n "${GROKBOT_ATOLL_ORG:-}" ] || { echo "Set GROKBOT_ATOLL_ORG in $DIR/config" >&2; exit 2; }
SINCE_EPOCH="$("$JQ" -n --arg s "$SINCE" '$s | fromdateiso8601')" || exit 2

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
# Pages of at most 1000 events, oldest first.
: > "$WORK/events"
from="$SINCE"
page() {
  local key base
  key="$(atoll_key)" || return 1
  base="$(atoll_base_url)" || return 1
  printf 'url = "%s/api/orgs/%s/agent-events/report?alias=%s&since=%s"\nheader = "Authorization: Bearer %s"\n' \
    "$base" "$GROKBOT_ATOLL_ORG" "$BOT" "$1" "$key" | curl -q -sS -f -m 30 -K -
}
for _ in $(seq 1 20); do
  page "$from" > "$WORK/page" || { echo "Atoll report failed" >&2; exit 1; }
  "$JQ" -c '.events[]' "$WORK/page" >> "$WORK/events"
  [ "$("$JQ" -r '.truncated' "$WORK/page")" = true ] || break
  from="$("$JQ" -r '.events[-1].received_at | sub("\\+00:00$"; "Z")' "$WORK/page")"
done

# Direct pings of this bot since the start: "<event id> <direct result>".
awk -v bot="$BOT" -v since="$SINCE_EPOCH" '
  $2 == bot && $3 == "atoll" && $4 ~ /^at=/ {
    split($4, at, "="); if (at[2] + 0 < since) next
    id = ""; direct = ""
    for (i = 5; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "event_id") id = kv[2]; if (kv[1] == "direct") direct = kv[2] }
    if (id != "") print id, direct
  }' "$LOG" "$LOG.1" 2>/dev/null > "$WORK/direct"

"$JQ" -n -r --rawfile direct "$WORK/direct" --slurpfile events "$WORK/events" '
  ($events | unique_by(.event_id)) as $seen
  | ($direct | split("\n") | map(select(length > 0) | split(" ") | {id: .[0], result: .[1]})) as $pings
  | ($pings | map(select(.result == "0") | .id)) as $sent
  | ($seen | map({key: .event_id, value: .}) | from_entries) as $by
  | ($sent | map(select($by[.] == null))) as $missing
  | ($sent | map($by[.] // empty | select(.would_forward != "forward"))) as $held
  | ($sent | map({key: ., value: true}) | from_entries) as $was
  | ($seen | map(select(.would_forward == "forward" and $was[.event_id] == null))) as $extra
  | ($seen | map(.latency_ms | numbers) | sort) as $ms
  | "direct pings: \($sent | length)",
    "events in Atoll: \($seen | length)",
    "direct pings missing in Atoll: \($missing | length)", ($missing[] | "  \(.)"),
    "direct pings Atoll would not forward: \($held | length)",
    ($held[] | "  \(.event_id) \(.status_word) would_forward=\(.would_forward)"),
    "Atoll would forward, no direct ping: \($extra | length)", ($extra[] | "  \(.event_id) \(.status_word)"),
    "p95 hook to Atoll ms: \(if ($ms | length) == 0 then "-" else $ms[(($ms | length) * 0.95 | ceil) - 1] end)"
'
