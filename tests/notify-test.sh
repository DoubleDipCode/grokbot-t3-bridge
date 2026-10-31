#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state"
export GROKBOT_STALE_SECONDS=7200 CALLS="$TMP/calls"
mkdir -p "$HOME" "$GROKBOT_HOOKS_DIR" "$TMP/bin" "$TMP/work"
git -C "$TMP/work" init -q
printf 'test\n' > "$TMP/work/.grokbot"
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/test.env"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then
    printf '%s\n' "$2" | jq -c . >> "$CALLS"
    break
  fi
  shift
done
if [ -n "${PAUSE_CURL:-}" ]; then
  printf '%s\n' "$PPID" > "$PAUSE_CURL/owner"
  while [ ! -f "$PAUSE_CURL/release" ]; do sleep 0.02; done
fi
printf 200
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
touch "$CALLS"
run() {
  local before i after
  before=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
  if [ "${1:-}" = sweep ]; then
    bash "$REPO/hooks/notify.sh" --sweep
  else
    printf '%s' "$1" > "$TMP/work/.grokbot-status"
    jq -n --arg cwd "$TMP/work" '{cwd:$cwd}' | bash "$REPO/hooks/notify.sh" test
  fi
  for ((i=0; i<300; i++)); do
    after=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
    if [ "$after" -gt "$before" ]; then return; fi
    sleep 0.02
  done
  echo 'FAIL: worker did not finish' >&2; exit 1
}
count() { [ "$(wc -l < "$CALLS" | tr -d ' ')" = "$1" ] || { echo "FAIL: expected $1 sends"; exit 1; }; }
touch "$GROKBOT_HOOKS_DIR/notify.log"
run 'waiting on CI'; count 0
run idle; count 1
run 'done PR'; count 2
run 'done PR'; count 2
run 'needs_input question'; count 3
run 'needs_input question'; count 4
run 'failed build'; run 'failed build'; count 6
run 'unknown status'; count 7
run 'milestone build'; count 8
run $'done PR\n'; count 9
run 'done PR'; count 10
run 'waiting on CI'; count 10
# Change only the stored clock; no sleep of two hours is needed.
for state in "$GROKBOT_STATE_DIR"/*.json; do
  jq '.clock -= 3' "$state" > "$state.tmp"; mv "$state.tmp" "$state"
done
export GROKBOT_STALE_SECONDS=2
run sweep; count 11
jq -e 'select(.status == "stale waiting on CI")' "$CALLS" >/dev/null
export GROKBOT_STALE_SECONDS=7200
run sweep; count 11
rm "$TMP/work/.grokbot"
run sweep; count 12
jq -e 'select(.status | startswith("worktree_missing "))' "$CALLS" >/dev/null
run sweep; count 12
# A crashed lock holder must not block later runs.
perl -MFcntl=:flock -e '
  open my $lock, ">>", $ARGV[0] or die;
  flock($lock, LOCK_EX) or die;
  open my $ready, ">", $ARGV[1] or die;
  close $ready;
  sleep 30;
' "$GROKBOT_STATE_DIR/lock" "$TMP/locked" &
holder=$!
for ((i=0; i<300; i++)); do
  [ -f "$TMP/locked" ] && break
  sleep 0.02
done
[ -f "$TMP/locked" ]
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
# A leftover lock file is harmless; concurrent workers must send only once.
printf 'test\n' > "$TMP/work/.grokbot"
printf 'done concurrent' > "$TMP/work/.grokbot-status"
completed=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log")
target=$((completed + 8))
for ((i=0; i<8; i++)); do
  jq -n --arg cwd "$TMP/work" '{cwd:$cwd}' | bash "$REPO/hooks/notify.sh" test
done
for ((i=0; i<300; i++)); do
  [ "$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log")" -ge "$target" ] && break
  sleep 0.02
done
[ "$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log")" -ge "$target" ]
count 13
# Kill the actual worker during an HTTP request. Its curl child must retain
# the inherited lock until the request ends, even though no cache can be saved.
export PAUSE_CURL="$TMP/pause"
mkdir "$PAUSE_CURL"
printf 'done interrupted' > "$TMP/work/.grokbot-status"
jq -n --arg cwd "$TMP/work" '{cwd:$cwd}' | bash "$REPO/hooks/notify.sh" test
for ((i=0; i<300; i++)); do
  [ -f "$PAUSE_CURL/owner" ] && break
  sleep 0.02
done
[ -f "$PAUSE_CURL/owner" ]
kill -KILL "$(cat "$PAUSE_CURL/owner")"
if perl -MFcntl=:flock -e '
  open my $lock, ">>", $ARGV[0] or die;
  exit(flock($lock, LOCK_EX | LOCK_NB) ? 0 : 1);
' "$GROKBOT_STATE_DIR/lock"; then
  echo 'FAIL: interrupted request lost its lock'; exit 1
fi
touch "$PAUSE_CURL/release"
unset PAUSE_CURL
run 'done interrupted'
for ((i=0; i<300; i++)); do
  [ "$(wc -l < "$CALLS" | tr -d ' ')" = 15 ] && break
  sleep 0.02
done
bash "$REPO/hooks/notify.sh" --sweep
count 15
printf 'PASS: inherited lock on worker death, concurrency, abandoned lock, waiting, idle, dedupe, urgent repeats, unknown, milestone, byte identity, stale sweep/reset, missing marker\n'
