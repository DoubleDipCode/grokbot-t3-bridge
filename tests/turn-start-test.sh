#!/bin/bash
# Turn-start hook, dead-turn detection and the registry rows behind them. Isolated: temp HOME,
# hooks and state dirs, stub curl/pgrep/lsof. Touches no live config.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset T3CODE_THREAD_ID T3CODE_CLI_PATH GROKBOT_STALL_MINUTES GROKBOT_REGISTRY CLAUDE_CONFIG_DIR
export HOME="$TMP/home" T3CODE_HOME="$TMP/t3"
export GROKBOT_T3_CLI=/nonexistent GROKBOT_T3_DB_LOOKUP=0   # never reach the real T3
export GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state"
export CALLS="$TMP/calls" ACTIVE=0
mkdir -p "$TMP/bin" "$HOME" "$GROKBOT_HOOKS_DIR"
cp "$REPO/hooks/registry-lib.sh" "$GROKBOT_HOOKS_DIR/"
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/one.env"
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
printf 'p123\nn%s/sub\n' "$WORK"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; tail -n 6 "$GROKBOT_HOOKS_DIR/notify.log" >&2 2>/dev/null; exit 1; }
LOGF="$GROKBOT_HOOKS_DIR/notify.log"
now() { date +%s; }
# new_work <name> [nomarker]: a fresh worktree and a clean hooks/state dir.
new_work() {
  rm -rf "$GROKBOT_STATE_DIR" "$GROKBOT_HOOKS_DIR"/markers.tsv "$GROKBOT_HOOKS_DIR"/threads.sqlite*
  : > "$CALLS"
  export WORK="$TMP/$1"
  mkdir -p "$WORK/sub"
  WORK="$(cd "$WORK" && pwd -P)"
  [ "${2:-}" = nomarker ] || printf 'one\n' > "$WORK/.grokbot"
  KEY="$(printf '%s' "$WORK" | shasum -a 256 | awk '{print $1}')"
  rm -f "$WORK/.grokbot-status"
  ACTIVE=0
}
# hook <mode> [status]: runs a hook the way the harness does; waits for the backgrounded worker.
hook() {
  local mode="$1" before i
  [ -z "${2:-}" ] || printf '%s' "$2" > "$WORK/.grokbot-status"
  touch "$LOGF"
  before=$(grep -c worker-complete "$LOGF" || true)
  OUT="$(jq -n --arg cwd "$WORK" '{cwd:$cwd,session_id:"sess-1",prompt:"do it"}' | bash "$REPO/hooks/notify.sh" "$mode")"
  [ -z "$OUT" ] || fail "$mode hook printed to stdout (Claude would inject it as context): $OUT"
  case "${3:-wait}" in nowait) return ;; esac
  for ((i=0; i<300; i++)); do
    [ "$(grep -c worker-complete "$LOGF" || true)" -gt "$before" ] && return
    sleep 0.02
  done
  fail "$mode worker did not finish"
}
sweep() { bash "$REPO/hooks/notify.sh" --sweep; }
count() { [ "$(wc -l < "$CALLS" | tr -d ' ')" = "$1" ] || fail "expected $1 sends, got $(wc -l < "$CALLS" | tr -d ' ')"; }
# Move a state timestamp or a file mtime into the past (minutes ago).
set_epoch() { printf '%s\n' "$(( ($(now) - $2 * 60) * 1000000 ))" > "$GROKBOT_STATE_DIR/$KEY.$1"; }
# Move both turn files back in time together, keeping their order.
shift_turns() {
  local f
  for f in turn_started turn_ended; do
    [ ! -f "$GROKBOT_STATE_DIR/$KEY.$f" ] || printf '%s\n' "$(( $(cat "$GROKBOT_STATE_DIR/$KEY.$f") - $1 * 60000000 ))" > "$GROKBOT_STATE_DIR/$KEY.$f"
  done
}
# The Stop ping stores a delivery clock the existing stall rule also honours: age it too.
old_clock() {
  local f="$GROKBOT_STATE_DIR/$KEY.json"
  [ ! -f "$f" ] || { jq '.clock = 1' "$f" > "$f.tmp"; mv "$f.tmp" "$f"; }
}
age_file() { perl -e 'utime time-$ARGV[1]*60, time-$ARGV[1]*60, $ARGV[0]' "$1" "$2"; }
age_tree() { find "$WORK" -path "$WORK/.git" -prune -o -type f -print | while read -r f; do age_file "$f" "$1"; done; }
row() { sqlite3 -batch "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT $1 FROM threads WHERE worktree='$WORK';"; }
last_status() { jq -r '.status' "$CALLS" | tail -n1; }

# --- 1a. First turn dies; the marker existed at turn start. ---
new_work t1a
export T3CODE_THREAD_ID=thread-1a
hook claude-start
unset T3CODE_THREAD_ID
[ -f "$GROKBOT_STATE_DIR/$KEY.turn_started" ] || fail 'turn_started not written'
grep -q "^$WORK	one$" "$GROKBOT_HOOKS_DIR/markers.tsv" || fail 'worktree not in markers.tsv at turn start'
[ "$(row status_word)" = running ] || fail "registry status: $(row status_word)"
[ "$(row thread_id)" = thread-1a ] || fail "registry thread id: $(row thread_id)"
[ "$(row harness)" = claude ] || fail "registry harness: $(row harness)"
[ "$(row started_at)" = "$(( $(cat "$GROKBOT_STATE_DIR/$KEY.turn_started") / 1000000 ))" ] || fail 'registry started_at'
count 0
sweep; count 0                          # fresh turn: not stalled yet
[ "$(row status_word)" = running ] || fail 'sweep overwrote running with the stale status'
set_epoch turn_started 50
sweep; count 1
jq -e 'select(.bot == "one" and .harness == "sweep" and .thread_id == "thread-1a" and .status == "stalled 50m turn_died no_status")' "$CALLS" >/dev/null \
  || fail "first-turn death payload: $(cat "$CALLS")"
[ "$(row status_word)" = stalled ] || fail "registry after ping: $(row status_word)"
sweep; sweep; count 1                   # once per dead turn

# --- 1b. First turn dies; .grokbot did not exist yet at turn start (T3 worktree, env thread id). ---
new_work t1b nomarker
export T3CODE_THREAD_ID=thread-1b
hook claude-start '' nowait
unset T3CODE_THREAD_ID
[ -f "$GROKBOT_STATE_DIR/pending/$KEY" ] || fail 'pending start not recorded'
[ ! -e "$GROKBOT_STATE_DIR/$KEY.turn_started" ] || fail 'turn_started written without a marker'
[ ! -f "$GROKBOT_HOOKS_DIR/markers.tsv" ] || fail 'markers.tsv written without a marker'
printf 'one\n' > "$WORK/.grokbot"                       # the thread's first command
sweep; count 0                                           # adopted, not old enough
grep -q "^$WORK	one$" "$GROKBOT_HOOKS_DIR/markers.tsv" || fail 'sweep did not adopt the worktree'
[ "$(row status_word)" = running ] && [ "$(row thread_id)" = thread-1b ] || fail "adopted row: $(row status_word) $(row thread_id)"
[ ! -e "$GROKBOT_STATE_DIR/pending/$KEY" ] || fail 'pending start left behind'
set_epoch turn_started 50
sweep; count 1
[ "$(last_status)" = "stalled 50m turn_died no_status" ] || fail "status: $(last_status)"

# --- 1c. Pending start, and the turn ends normally before any sweep: nothing to report. ---
new_work t1c nomarker
export T3CODE_THREAD_ID=thread-1c
hook claude-start '' nowait
unset T3CODE_THREAD_ID
printf 'one\n' > "$WORK/.grokbot"
hook claude 'done PR'; count 1
[ ! -e "$GROKBOT_STATE_DIR/pending/$KEY" ] || fail 'Stop left the pending start'
age_tree 120; sweep; count 1

# --- 1d. Not a T3 worktree and no marker: the start hook records nothing at all. ---
new_work t1d nomarker
hook claude-start '' nowait
[ ! -e "$GROKBOT_STATE_DIR/pending" ] && [ ! -e "$GROKBOT_HOOKS_DIR/markers.tsv" ] || fail 'start hook acted outside a marked/T3 worktree'
[ ! -e "$GROKBOT_STATE_DIR/$KEY.turn_started" ] || fail 'turn_started written outside a marked worktree'
# ... and a T3 worktree path counts without the env var.
T3W="$T3CODE_HOME/worktrees/proj/wt"; mkdir -p "$T3W"
jq -n --arg cwd "$T3W" '{cwd:$cwd}' | bash "$REPO/hooks/notify.sh" claude-start
K2="$(printf "%s" "$T3W" | shasum -a 256 | awk "{print \$1}")"
[ -f "$GROKBOT_STATE_DIR/pending/$K2" ] || fail 'T3 worktree path not recognised'

# --- 2. Follow-up turn on a done thread dies. ---
new_work t2
hook claude 'done PR'; count 1
[ -f "$GROKBOT_STATE_DIR/$KEY.turn_ended" ] || fail 'Stop did not record turn_ended'
sweep; count 1                                           # done and no open turn: unchanged
age_tree 180; set_epoch turn_ended 170
sweep; count 1
hook claude-start
[ "$(row status_word)" = running ] || fail "follow-up turn row: $(row status_word)"
age_file "$WORK/.grokbot-status" 180
set_epoch turn_started 46
sweep; count 2
[ "$(last_status)" = "stalled 46m turn_died done PR" ] || fail "status: $(last_status)"
sweep; count 2
hook claude-start                                        # another follow-up, dies too
set_epoch turn_started 47
sweep; count 3
[ "$(last_status)" = "stalled 47m turn_died done PR" ] || fail "status: $(last_status)"
hook claude 'done PR again'; count 4                     # a late Stop closes the turn
set_epoch turn_started 400; set_epoch turn_ended 1
sweep; count 4

# --- 3. Follow-up turn on a waiting thread dies. ---
new_work w3
hook claude 'waiting CI'; count 0
hook claude-start
age_file "$WORK/.grokbot-status" 60
set_epoch turn_ended 100; set_epoch turn_started 46
sweep; count 1
[ "$(last_status)" = "stalled 46m turn_died waiting CI" ] || fail "status: $(last_status)"
sweep; count 1

# --- 4. Normal turns: no false pings. ---
new_work t4
hook claude-start
hook claude 'done PR'; count 1
hook claude-start
hook claude 'done PR'; count 1                           # duplicate Stop, as before
age_tree 100; set_epoch turn_started 95; set_epoch turn_ended 90
sweep; count 1
new_work t4b
hook claude-start
age_file "$WORK/.grokbot-status" 5 2>/dev/null || true
set_epoch turn_started 10
sweep; count 0                                           # young turn, no harness
hook claude 'done PR'; count 1
set_epoch turn_started 99; set_epoch turn_ended 98
age_tree 98
sweep; count 1                                           # the turn ended: nothing to report

# --- 4c. A turn that starts and ends within the same second is closed, not dead. ---
new_work t4c
hook claude-start
hook claude 'done quick'; count 1
shift_turns 100; age_tree 100
sweep; count 1
[ "$(cat "$GROKBOT_STATE_DIR/$KEY.turn_started")" -lt "$(cat "$GROKBOT_STATE_DIR/$KEY.turn_ended")" ] || fail 'Stop not ordered after start'

# --- 4d. Late workers do not overwrite the row of a newer start or end. ---
new_work t4d
hook claude-start
# shellcheck disable=SC2034 # the library reads these globals
ev() { # ev <mode> <word> <us>: a registry write as a delayed worker would do it
  ( set +eu; DIR="$GROKBOT_HOOKS_DIR"; STATE="$GROKBOT_STATE_DIR"; LOG="$LOGF"; MAP="$DIR/markers.tsv"; JQ=jq
    . "$REPO/hooks/registry-lib.sh"
    ROOT="$WORK" BOT=one HARNESS=claude SESSION='' LAST='' STATUS="$2" WORD="$2" TS=t EVENT_US="$3"
    registry_record "$1" )
}
ev turn 'done' 5                                           # an old Stop arrives after the newer start
[ "$(row status_word)" = running ] && [ -n "$(row started_at)" ] || fail 'late Stop overwrote a newer start'
ev turn 'done' 99999999999999999
[ "$(row status_word)" = "done" ] && [ -z "$(row started_at)" ] || fail 'Stop did not apply'
ev start running 6                                       # an old start arrives after the newer Stop
[ "$(row status_word)" = "done" ] && [ -z "$(row started_at)" ] || fail 'late start overwrote a newer Stop'

# --- 4e. Adopting another worktree's pending start leaves the current hook's harness alone. ---
new_work t4e
mkdir -p "$TMP/other"; OTHER="$(cd "$TMP/other" && pwd -P)"
OKEY="$(printf '%s' "$OTHER" | shasum -a 256 | awk '{print $1}')"
mkdir -p "$GROKBOT_STATE_DIR/pending"
printf '%s\n%s\n%s\n%s\n%s\n' "$OTHER" "$(( $(now) * 1000000 ))" thread-o claude-start sess-o > "$GROKBOT_STATE_DIR/pending/$OKEY"
printf 'one\n' > "$OTHER/.grokbot"
hook codex 'done PR'
jq -e 'select(.harness == "codex" and .worktree == "'"$WORK"'")' "$CALLS" >/dev/null || fail "payload harness clobbered: $(cat "$CALLS")"
[ "$(row harness)" = codex ] || fail "row harness: $(row harness)"
[ "$(sqlite3 -batch "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT harness||status_word FROM threads WHERE worktree='$OTHER'")" = claude-startrunning ] || [ "$(sqlite3 -batch "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT harness||status_word FROM threads WHERE worktree='$OTHER'")" = clauderunning ] || fail 'other worktree not adopted'

# --- 5. Harness alive and quiet: the approval? rule is unchanged. ---
new_work t5
hook claude 'in_progress build'; count 1                 # the Stop ping
hook claude-start
age_tree 50; set_epoch turn_ended 90; set_epoch turn_started 50; old_clock
ACTIVE=1 sweep; count 2
[ "$(last_status)" = "stalled 45m approval? in_progress build" ] || fail "status: $(last_status)"
ACTIVE=1 sweep; count 2
new_work t5b                                             # alive and busy: nothing
hook claude 'in_progress build'; count 1
hook claude-start
age_file "$WORK/.grokbot-status" 50; set_epoch turn_ended 90; set_epoch turn_started 50; old_clock   # other files are fresh
ACTIVE=1 sweep; count 1
new_work t5c                                             # alive, quiet, status done: still skipped
hook claude 'done PR'; count 1
hook claude-start
age_tree 50; set_epoch turn_ended 90; set_epoch turn_started 50; old_clock
ACTIVE=1 sweep; count 1

# --- 6. Threshold comes from GROKBOT_STALL_MINUTES. ---
new_work t6
hook claude 'done PR'; count 1
hook claude-start
age_file "$WORK/.grokbot-status" 20; set_epoch turn_ended 90; set_epoch turn_started 20
sweep; count 1
GROKBOT_STALL_MINUTES=10 sweep; count 2
[ "$(last_status)" = "stalled 20m turn_died done PR" ] || fail "status: $(last_status)"

# --- 7. A registry made before this feature (no started_at column) is upgraded in place. ---
new_work w7
sqlite3 -batch "$GROKBOT_HOOKS_DIR/threads.sqlite" "CREATE TABLE threads (worktree TEXT PRIMARY KEY, bot TEXT NOT NULL, thread_id TEXT, thread_source TEXT, title TEXT, project_id TEXT, branch TEXT, harness TEXT, session_id TEXT, status_word TEXT, status_note TEXT, last_message TEXT, pr_url TEXT, t3_status TEXT, archived INTEGER NOT NULL DEFAULT 0, settled INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','done','worktree_missing','archived','settled','removed')), final_since INTEGER, first_seen TEXT NOT NULL, updated_at TEXT NOT NULL, enriched_at INTEGER, resolve_tried INTEGER); CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT); INSERT INTO meta VALUES ('schema_version','1'),('migrated_markers','x');"
hook claude-start
[ "$(row status_word)" = running ] && [ -n "$(row started_at)" ] || fail 'old registry not upgraded'
hook claude 'done PR'
[ "$(row status_word)" = "done" ] && [ -z "$(row started_at)" ] || fail "Stop did not clear the running turn: $(row status_word) '$(row started_at)'"

echo 'PASS: turn start (marker, pending, T3 detection), first-turn death, death after done and waiting, once per dead turn, normal turns, alive-and-quiet approval?, threshold, old registry upgrade'
