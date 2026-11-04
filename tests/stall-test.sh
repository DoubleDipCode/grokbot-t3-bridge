#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state"
export CALLS="$TMP/calls" ACTIVE=0
mkdir -p "$TMP/bin" "$TMP/work/sub" "$GROKBOT_HOOKS_DIR"
WORK="$(cd "$TMP/work" && pwd -P)"
export WORK
printf 'one\n' > "$WORK/.grokbot"
printf 'in_progress build\n' > "$WORK/.grokbot-status"
printf '%s\tone\n' "$WORK" > "$GROKBOT_HOOKS_DIR/markers.tsv"
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/one.env"
cp "$GROKBOT_HOOKS_DIR/one.env" "$GROKBOT_HOOKS_DIR/two.env"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then printf '%s\n' "$2" | jq -c . >> "$CALLS"; break; fi
  shift
done
printf 200
STUB
cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/bash
[ "$ACTIVE" != 0 ] || exit 1
echo 123
STUB
cat > "$TMP/bin/lsof" <<'STUB'
#!/bin/bash
[ "$ACTIVE" != error ] || exit 1
printf 'p123\nn%s/sub\n' "$WORK"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
touch "$CALLS"
age() {
  perl -e 'utime time-($ARGV[1]*60), time-($ARGV[1]*60), $ARGV[0]' "$WORK/.grokbot-status" "$1"
}
sweep() { bash "$REPO/hooks/notify.sh" --sweep; }
count() { [ "$(wc -l < "$CALLS" | tr -d ' ')" = "$1" ]; }
old_clock() {
  for state in "$GROKBOT_STATE_DIR"/*.json; do
    case "$state" in *.observed.json) continue ;; esac
    jq '.clock = 1' "$state" > "$state.tmp"; mv "$state.tmp" "$state"
  done
}
age 44; sweep; count 0
age 46; sweep; count 1
jq -e 'select(.status | startswith("stalled 46m in_progress build"))' "$CALLS"
old_clock; sweep; count 1
printf 'in_progress tests\n' > "$WORK/.grokbot-status"
age 46; sweep; count 2
# A recent successful ping takes precedence over an old status.
printf 'in_progress recent ping\n' > "$WORK/.grokbot-status"
age 46; sweep; count 2
old_clock
export ACTIVE=1
sweep; count 2
export ACTIVE=error
sweep; count 2
export ACTIVE=0
sweep; count 3
printf 'done PR\n' > "$WORK/.grokbot-status"
age 180; old_clock; sweep; count 3
printf 'waiting CI\n' > "$WORK/.grokbot-status"
# Fresh ping clock: still no stale waiting at 45 minutes.
for state in "$GROKBOT_STATE_DIR"/*.json; do
  case "$state" in *.observed.json) continue ;; esac
  jq --argjson now "$(date +%s)" '.clock = $now - 2700' "$state" > "$state.tmp"; mv "$state.tmp" "$state"
done
sweep; count 3
old_clock; sweep; count 4
old_clock; sweep; count 4
jq -e 'select(.status == "stale waiting CI\n")' "$CALLS"
# A second bot and configurable threshold.
printf 'two\n' > "$WORK/.grokbot"
printf 'idle\n' > "$WORK/.grokbot-status"
age 2; old_clock
export GROKBOT_STALL_MINUTES=1
sweep; count 5
jq -e 'select(.bot == "two" and (.status | startswith("stalled 2m idle")))' "$CALLS"
# Missing configuration must not consume an attempt.
printf 'idle no endpoint\n' > "$WORK/.grokbot-status"
age 2; old_clock
mv "$GROKBOT_HOOKS_DIR/two.env" "$TMP/two.env"
sweep; count 5
mv "$TMP/two.env" "$GROKBOT_HOOKS_DIR/two.env"
sweep; count 6
# Local config file ($GROKBOT_HOOKS_DIR/config): its threshold applies when the environment sets
# none, and a real environment variable beats it. The file is parsed, never run.
cp "$REPO/hooks/config-lib.sh" "$GROKBOT_HOOKS_DIR/"
unset GROKBOT_STALL_MINUTES
printf 'GROKBOT_STALL_MINUTES=1\ntouch "%s/ran"\n' "$TMP" > "$GROKBOT_HOOKS_DIR/config"
printf 'idle config file\n' > "$WORK/.grokbot-status"
age 2; old_clock
GROKBOT_STALL_MINUTES=60 sweep; count 6
sweep; count 7
jq -e 'select(.status | startswith("stalled 2m idle config file"))' "$CALLS"
[ ! -e "$TMP/ran" ] || { echo 'FAIL: config file ran code'; exit 1; }
echo 'PASS: stall age, dedupe, reset, ping clock, active harness, failed check, done, waiting, bot routing, threshold, config file'
