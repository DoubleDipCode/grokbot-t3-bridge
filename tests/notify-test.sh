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

# ---- Approval prompts: claude-notify and codex-permission --------------------------------
printf 'test\n' > "$TMP/work/.grokbot"
printf 'milestone build running' > "$TMP/work/.grokbot-status"
mkdir -p "$TMP/work/sub/dir"
approve() {   # approve <mode> <json>: waits for the backgrounded ping to finish
  local before i
  before=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
  printf '%s' "$2" | bash "$REPO/hooks/notify.sh" "$1"
  for ((i=0; i<300; i++)); do
    [ "$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)" -gt "$before" ] && return
    sleep 0.02
  done
  echo "FAIL: $1 ping did not finish" >&2; exit 1
}
before_total=$(wc -l < "$CALLS" | tr -d ' ')
total() { [ "$(wc -l < "$CALLS" | tr -d ' ')" = "$((before_total + $1))" ] || { echo "FAIL: expected $1 new sends, have $(( $(wc -l < "$CALLS" | tr -d ' ') - before_total ))"; exit 1; }; }
last() { tail -n 1 "$CALLS" | jq -r "$1"; }
# Fake transcript whose last tool_use is the command waiting for approval.
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm publish --dry-run","description":"Publish"}}]}}' \
  > "$TMP/transcript.jsonl"
approve claude-notify "$(jq -n --arg cwd "$TMP/work/sub/dir" --arg t "$TMP/transcript.jsonl" \
  '{cwd:$cwd,session_id:"s1",transcript_path:$t,hook_event_name:"Notification",notification_type:"permission_prompt",message:"Claude needs your permission to use Bash"}')"
total 1
[ "$(last .status)" = 'needs_input approval Bash: npm publish --dry-run' ] || { echo "FAIL: claude summary: $(last .status)"; exit 1; }
[ "$(last .harness)" = claude-notify ] && [ "$(last .session_id)" = s1 ] || { echo 'FAIL: claude identity'; exit 1; }
[ "$(basename "$(last .worktree)")" = work ] || { echo 'FAIL: parent marker lookup'; exit 1; }
# No dedupe: the identical prompt pings again. Without a transcript the message is the summary.
approve claude-notify "$(jq -n --arg cwd "$TMP/work" \
  '{cwd:$cwd,notification_type:"permission_prompt",message:"Claude needs your permission to use Bash"}')"
total 2
[ "$(last .status)" = 'needs_input approval Claude needs your permission to use Bash' ] || { echo "FAIL: message summary: $(last .status)"; exit 1; }
# Older Claude versions send no notification_type.
approve claude-notify "$(jq -n --arg cwd "$TMP/work" '{cwd:$cwd,message:"Claude needs your permission to use Edit"}')"
total 3
# Not about approval: ignored (idle_prompt, auth_success, legacy idle text).
for payload in \
  '{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}' \
  '{"notification_type":"auth_success","message":"Authenticated"}' \
  '{"message":"Claude is waiting for your input"}'; do
  printf '%s' "$payload" | jq --arg cwd "$TMP/work" '. + {cwd:$cwd}' | bash "$REPO/hooks/notify.sh" claude-notify
done
sleep 1
total 3
# .grokbot-status is never touched.
[ "$(cat "$TMP/work/.grokbot-status")" = 'milestone build running' ] || { echo 'FAIL: status file changed'; exit 1; }
# Elicitation counts as input.
approve claude-notify "$(jq -n --arg cwd "$TMP/work" '{cwd:$cwd,notification_type:"elicitation_dialog",message:"Form open\nline two"}')"
total 4
[ "$(last .status)" = 'needs_input approval Form open
line two' ] && { echo 'FAIL: newline kept'; exit 1; }
[ "$(last .status)" = 'needs_input approval Form open line two' ] || { echo "FAIL: newline collapse: $(last .status)"; exit 1; }
# Codex PermissionRequest.
approve codex-permission "$(jq -n --arg cwd "$TMP/work" \
  '{cwd:$cwd,session_id:"c1",hook_event_name:"PermissionRequest",tool_name:"Bash",tool_input:{command:"rm -rf build",description:"Remove the build dir"}}')"
total 5
[ "$(last .status)" = 'needs_input approval Bash: Remove the build dir' ] || { echo "FAIL: codex summary: $(last .status)"; exit 1; }
approve codex-permission "$(jq -n --arg cwd "$TMP/work" \
  '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"apply_patch *** Begin Patch"}}')"
total 6
[ "$(last .status)" = 'needs_input approval apply_patch: apply_patch *** Begin Patch' ] || { echo "FAIL: codex command: $(last .status)"; exit 1; }
# Long summaries are cut to 200 bytes.
approve codex-permission "$(jq -n --arg cwd "$TMP/work" --arg c "$(printf 'x%.0s' {1..500})" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}')"
total 7
[ "$(last '.status | length')" -le 222 ] || { echo 'FAIL: summary not truncated'; exit 1; }
# A directory with no marker and no map entry sends nothing.
mkdir "$TMP/other" && git -C "$TMP/other" init -q
jq -n --arg cwd "$TMP/other" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' | bash "$REPO/hooks/notify.sh" codex-permission
sleep 1
total 7
grep -q 'codex-permission no-marker' "$GROKBOT_HOOKS_DIR/notify.log" || { echo 'FAIL: no-marker not logged'; exit 1; }
# A missing marker for a known worktree still pings through the marker map.
rm "$TMP/work/.grokbot"
approve codex-permission "$(jq -n --arg cwd "$TMP/work" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}')"
total 8
printf 'test\n' > "$TMP/work/.grokbot"

# ---- Sweep stall fallback ------------------------------------------------------------------
before_total=$(wc -l < "$CALLS" | tr -d ' ')
export GROKBOT_STALL_MINUTES=45
ln -s /bin/sleep "$TMP/bin/claude"
( cd "$TMP/work" && exec "$TMP/bin/claude" 300 </dev/null >/dev/null 2>&1 ) &
fake_harness=$!
trap 'kill "$fake_harness" 2>/dev/null; rm -rf "$TMP"' EXIT
for ((i=0; i<100; i++)); do
  /usr/sbin/lsof -a -d cwd -Fn -p "$fake_harness" 2>/dev/null | grep -q work && break
  sleep 0.05
done
backdate() { find "$TMP/work" -exec touch -t 202001010000 {} +; }
slug() { printf '%s' "$(cd "$TMP/work" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g'; }
printf 'milestone building the thing' > "$TMP/work/.grokbot-status"
# Recent activity (just written files): no stall.
run sweep; total 0
# Quiet for longer than the threshold: one ping.
backdate
run sweep; total 1
[ "$(last .status)" = 'stalled 45m approval? milestone building the thing' ] || { echo "FAIL: stall status: $(last .status)"; exit 1; }
[ "$(last .harness)" = sweep ] || { echo 'FAIL: stall harness'; exit 1; }
# One ping per stall.
run sweep; total 1
# Activity ends the stall; a new stall with the same status file pings again.
touch "$TMP/work/newfile"
run sweep; total 1
rm "$TMP/work/newfile"; backdate
run sweep; total 2
# A recent session log counts as activity (long builds that write only the log).
mkdir -p "$HOME/.claude-test/projects/$(slug)"
touch "$HOME/.claude-test/projects/$(slug)/s.jsonl"
backdate
printf 'milestone another status' > "$TMP/work/.grokbot-status"; backdate
run sweep; total 2
rm -rf "$HOME/.claude-test"
run sweep; total 3
[ "$(last .status)" = 'stalled 45m approval? milestone another status' ] || { echo "FAIL: stall status 2: $(last .status)"; exit 1; }
# Finished statuses are not stalls, even with an idle harness open.
for st in 'done PR' 'idle' 'failed x' 'needs_input q' 'waiting on CI'; do
  printf '%s' "$st" > "$TMP/work/.grokbot-status"; backdate
  run sweep
done
total 3
# No harness running in the worktree: no stall ping.
kill "$fake_harness"; wait "$fake_harness" 2>/dev/null || true
printf 'milestone orphan' > "$TMP/work/.grokbot-status"; backdate
run sweep; total 3
unset GROKBOT_STALL_MINUTES

printf 'PASS: approval pings (Claude Notification, Codex PermissionRequest, filtering, no dedupe), stall sweep, inherited lock on worker death, concurrency, abandoned lock, waiting, idle, dedupe, urgent repeats, unknown, milestone, byte identity, stale sweep/reset, missing marker\n'
