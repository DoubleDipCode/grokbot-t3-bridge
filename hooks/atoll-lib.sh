#!/bin/bash
# shellcheck disable=SC2016,SC2153,SC2154 # jq programs; the ping globals (BOT, ROOT, STATUS, ...) are set by notify.sh
# Send hook events to Atoll first. Meant to be sourced by notify.sh. See docs/atoll.md.
#
# Per bot, from the config: off (default), shadow (direct post as before, plus a record-only copy
# to Atoll) or live (Atoll first; direct post when Atoll fails or does not forward). Nothing here
# prints the API key, and the key is never a process argument or exported.

ATOLL_TIMEOUT=4
ATOLL_SPOOL="$DIR/atoll-spool"

# atoll_mode <bot>: prints off, shadow or live.
atoll_mode() {
  local bot="$1" list
  [ -n "${GROKBOT_ATOLL_ORG:-}" ] && [ -n "$bot" ] || { printf off; return; }
  list=" $(printf '%s' "${GROKBOT_ATOLL_LIVE_BOTS:-}" | tr ',' ' ') "
  case "$list" in *" $bot "*|*" * "*) printf live; return ;; esac
  list=" $(printf '%s' "${GROKBOT_ATOLL_SHADOW_BOTS:-}" | tr ',' ' ') "
  case "$list" in *" $bot "*|*" * "*) printf shadow; return ;; esac
  printf off
}

# The key: GROKBOT_ATOLL_KEY_FILE, else the macOS Keychain, else $DIR/atoll.key (mode 600).
atoll_key() {
  local key=
  if [ -n "${GROKBOT_ATOLL_KEY_FILE:-}" ]; then
    key="$(head -n1 "$GROKBOT_ATOLL_KEY_FILE" 2>/dev/null)"
  else
    command -v security >/dev/null 2>&1 && key="$(security find-generic-password -s grokbot-atoll-key -w 2>/dev/null)"
    [ -n "$key" ] || key="$(head -n1 "$DIR/atoll.key" 2>/dev/null)"
  fi
  # Refuse anything that could add a line or an option to the curl config.
  case "$key" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$key"
}

atoll_base_url() {
  local url="${GROKBOT_ATOLL_URL:-https://atollhq.com}"
  url="${url%/}"
  case "$url" in
    *[\"\\[:space:]]*) return 1 ;;
    https://*|http://127.0.0.1:*|http://localhost:*) printf '%s' "$url" ;;
    *) return 1 ;;
  esac
}

# atoll_request <url path> [body file]: sets ATOLL_HTTP (000 on no answer) and ATOLL_RESPONSE.
atoll_request() {
  local key base out
  ATOLL_HTTP=000
  ATOLL_RESPONSE=
  key="$(atoll_key)" || { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') atoll no-key" >> "$LOG"; return 1; }
  base="$(atoll_base_url)" || { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') atoll bad-url" >> "$LOG"; return 1; }
  out="$(mktemp "$DIR/.atoll-response.XXXXXX")" || return 1
  ATOLL_HTTP="$({
    printf 'url = "%s%s"\n' "$base" "$1"
    printf 'header = "Authorization: Bearer %s"\n' "$key"
    printf 'header = "Content-Type: application/json"\n'
    [ -z "${2:-}" ] || printf 'data-binary = "@%s"\n' "$2"
    printf 'output = "%s"\n' "$out"
    printf 'write-out = "%%{http_code}"\n'
  } | curl -q -sS -m "$ATOLL_TIMEOUT" -K - 2>/dev/null)" || ATOLL_HTTP=000
  ATOLL_RESPONSE="$(head -c 4000 "$out" 2>/dev/null)"
  rm -f "$out"
  [ -n "$ATOLL_HTTP" ] || ATOLL_HTTP=000
}

# atoll_send <event json>
atoll_send() {
  local body
  body="$(mktemp "$DIR/.atoll-event.XXXXXX")" || { ATOLL_HTTP=000; ATOLL_RESPONSE=; return 1; }
  printf '%s' "$1" > "$body"
  atoll_request "/api/orgs/$GROKBOT_ATOLL_ORG/agent-events" "$body"
  rm -f "$body"
}

# A failure that a later replay can fix.
atoll_retryable() {
  case "$1" in 000|408|429|5??) return 0 ;; esac
  return 1
}

atoll_uuid() {
  local id
  id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  printf '%s' "$id" | tr 'A-F' 'a-f'
}

# atoll_time <epoch microseconds>: UTC ISO 8601 with milliseconds.
atoll_time() {
  perl -MPOSIX=strftime -e 'my $u = shift; my $s = int($u / 1000000);
    printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime($s)), int(($u - $s * 1000000) / 1000)' "$1"
}

# atoll_seq <thread id> <now us>: sets ATOLL_SEQ, a number that only grows per thread.
atoll_seq() {
  local file last
  mkdir -p "$STATE/atoll-seq" 2>/dev/null
  file="$STATE/atoll-seq/$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')"
  last="$(cat "$file" 2>/dev/null)"
  case "$last" in *[!0-9]*|'') last=0 ;; esac
  ATOLL_SEQ="$2"
  [ "$ATOLL_SEQ" -gt "$last" ] || ATOLL_SEQ=$((last + 1))
  printf '%s\n' "$ATOLL_SEQ" > "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
}

# atoll_event <deliver true|false> <event id>: the event for the current ping, from the same
# globals as the direct body. No worktree, cwd or transcript path is sent. Returns 1 when the
# ping has no thread identity, so Atoll cannot record it.
atoll_event() {
  local thread harness kind now occurred pr issue=
  if [ -n "${THREAD_ID:-}" ]; then
    thread="$THREAD_ID"; harness=t3
  elif [ -n "${SESSION:-}" ]; then
    thread="$SESSION"
    case "$HARNESS" in claude*) harness=claude ;; codex*) harness=codex ;; *) harness=cli ;; esac
  else
    return 1
  fi
  case "$thread" in *[[:space:]]*) return 1 ;; esac
  case "$HARNESS" in
    sweep) kind=sweep ;;
    claude-notify|codex-permission) kind=approval ;;
    *) kind=turn_ended ;;
  esac
  hook_now_us
  now="$ATOLL_NOW_US"
  occurred="$now"
  # A turn end carries the time its Stop hook fired, so latency is measured from there.
  if [ "$kind" = turn_ended ]; then
    case "${EVENT_US:-}" in *[!0-9]*|'') ;; *) occurred="$EVENT_US" ;; esac
  fi
  atoll_seq "$thread" "$now"
  pr="$(printf '%s' "$STATUS" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' | head -n1)"
  case "${ROUTE:-marker}" in marker|map) issue="$(marker_issue "$ROOT")" ;; esac
  "$JQ" -n --arg event_id "$2" --arg kind "$kind" --arg alias "$BOT" --arg route "${ROUTE:-marker}" \
    --arg harness "$harness" --arg thread "$thread" --arg title "${THREAD_TITLE:-}" \
    --arg host "$(hostname -s 2>/dev/null)" --arg parent "${PARENT_ID:-}" --arg parent_title "${PARENT_TITLE:-}" \
    --arg project "${PROJECT_ID:-}" --arg issue "$issue" --arg branch "${BRANCH:-}" --arg status "$STATUS" \
    --arg pr "$pr" --arg excerpt "${LAST:-}" --arg occurred "$(atoll_time "$occurred")" \
    --argjson seq "$ATOLL_SEQ" --argjson deliver "$1" '
    def opt($key; $value; $max): if $value == "" then {} else {($key): $value[0:$max]} end;
    {event_id: $event_id, kind: $kind, alias: $alias, route: $route, harness: $harness,
     thread: ({id: $thread} + opt("title"; $title; 1000) + opt("host_id"; $host; 255)
       + opt("parent_id"; $parent; 255) + opt("parent_title"; $parent_title; 1000) + opt("project_id"; $project; 255)),
     status: $status[0:2000], occurred_at: $occurred, seq: $seq, deliver: $deliver, fallback_delivered: false}
    + opt("issue"; $issue; 64) + opt("branch"; $branch; 255) + opt("pr_url"; $pr; 500) + opt("excerpt"; $excerpt; 1500)'
}

hook_now_us() {
  ATOLL_NOW_US="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000' 2>/dev/null)"
  case "$ATOLL_NOW_US" in *[!0-9]*|'') ATOLL_NOW_US="$(date +%s)000000" ;; esac
}

# atoll_spool <event json> <fallback delivered true|false>
atoll_spool() {
  local id
  mkdir -p "$ATOLL_SPOOL" 2>/dev/null || return 1
  id="$(printf '%s' "$1" | "$JQ" -r '.event_id')"
  printf '%s' "$1" | "$JQ" -c --argjson delivered "$2" '.fallback_delivered = $delivered' > "$ATOLL_SPOOL/.$id.tmp" \
    && mv -f "$ATOLL_SPOOL/.$id.tmp" "$ATOLL_SPOOL/$id.json"
}

# Replay the spool, oldest first. Stops at the first sign that Atoll is still down.
atoll_replay() {
  local file name count=0
  [ -d "$ATOLL_SPOOL" ] && [ -n "${GROKBOT_ATOLL_ORG:-}" ] || return 0
  # Older than seven days: no longer worth sending.
  find "$ATOLL_SPOOL" -type f -mtime +7 -delete 2>/dev/null
  # shellcheck disable=SC2012 # names are UUIDs, and the order must be by time
  while IFS= read -r name; do
    file="$ATOLL_SPOOL/$name"
    case "$name" in *.json) ;; *) continue ;; esac
    [ -f "$file" ] || continue
    [ "$count" -lt 10 ] || break
    count=$((count + 1))
    atoll_send "$(cat "$file")"
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') atoll replay event_id=${name%.json} http=$ATOLL_HTTP" >> "$LOG"
    if atoll_retryable "$ATOLL_HTTP"; then break; fi
    # Accepted, or refused in a way a retry cannot fix.
    rm -f "$file"
  done <<< "$(ls -tr "$ATOLL_SPOOL" 2>/dev/null)"
}

# atoll_record: a turn end that is not sent to the bot (waiting, or the same status again) still
# reaches Atoll, which moves the thread's execution from it. Record only: it is never forwarded.
atoll_record() {
  local event id
  [ "$(atoll_mode "$BOT")" != off ] || return 0
  registry_load_thread "$ROOT"
  id="$(atoll_uuid)"
  event="$(atoll_event false "$id")" && [ -n "$event" ] || return 0
  atoll_send "$event"
  ! atoll_retryable "$ATOLL_HTTP" || atoll_spool "$event" false
  atoll_log record "$id" "$ATOLL_HTTP" suppressed none
}

atoll_log() {
  echo "$TS $BOT atoll at=$(date +%s) mode=$1 event_id=$2 http=$3 reason=$4 direct=$5" >> "$LOG"
}

# post_atoll <shadow|live>: send the current ping. Same return codes as post_once.
post_atoll() {
  local mode="$1" id event rc forwarded reason answer
  registry_load_thread "$ROOT"
  id="$(atoll_uuid)"
  if ! event="$(atoll_event "$([ "$mode" = live ] && echo true || echo false)" "$id")" || [ -z "$event" ]; then
    echo "$TS $BOT atoll no-thread-identity" >> "$LOG"
    post_once ""
    return
  fi
  if [ "$mode" = shadow ]; then
    # Beside the direct post, so a slow Atoll never delays the ping.
    answer="$(mktemp "$DIR/.atoll-shadow.XXXXXX")" || { post_once ""; return; }
    ( atoll_send "$event"; printf '%s\n' "$ATOLL_HTTP" > "$answer" ) &
    post_once "$id"
    rc=$?
    wait
    ATOLL_HTTP="$(cat "$answer" 2>/dev/null)"
    rm -f "$answer"
    ! atoll_retryable "${ATOLL_HTTP:-000}" || atoll_spool "$event" false
    atoll_log shadow "$id" "${ATOLL_HTTP:-000}" shadow "$rc"
    return "$rc"
  fi
  atoll_send "$event"
  forwarded=false; reason=error
  if [ "$ATOLL_HTTP" = 202 ]; then
    forwarded="$(printf '%s' "$ATOLL_RESPONSE" | "$JQ" -r '.forwarded == true' 2>/dev/null)"
    reason="$(printf '%s' "$ATOLL_RESPONSE" | "$JQ" -r '.reason | strings' 2>/dev/null | tr -cd 'a-z_')"
  fi
  if [ "$forwarded" = true ]; then
    mark_stall_attempt || return 1
    atoll_log live "$id" "$ATOLL_HTTP" "$reason" none
    return 0
  fi
  post_once "$id"
  rc=$?
  atoll_log live "$id" "$ATOLL_HTTP" "$reason" "$rc"
  # 202 without forwarding is spooled too: the replay tells Atoll the ping went out directly.
  if [ "$ATOLL_HTTP" = 202 ] || atoll_retryable "$ATOLL_HTTP"; then
    atoll_spool "$event" "$([ "$rc" -eq 0 ] && echo true || echo false)"
  fi
  return "$rc"
}
