#!/bin/bash
# shellcheck disable=SC2015,SC2016 # the A && B || fail lines are checks, not if/else; single quotes keep $ literal
# Thread registry: thread id resolution (env, T3 database, T3 CLI), schema, markers.tsv migration,
# payload fields and the my_open_threads summary. Uses a fake `t3` command and a fake T3 database
# in a temporary directory. Never touches the real T3, ~/.grokbot-hooks or any Claude/Codex config.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset T3CODE_THREAD_ID T3CODE_CLI_PATH T3CODE_HOME GROKBOT_REGISTRY GROKBOT_SUMMARY_MAX
export HOME="$TMP/home" GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state" CALLS="$TMP/calls"
export FAKE_T3="$TMP/fake-t3" GROKBOT_T3_CLI="$TMP/bin/t3" GROKBOT_T3_DB="$TMP/t3.sqlite"
mkdir -p "$HOME" "$GROKBOT_HOOKS_DIR" "$TMP/bin" "$FAKE_T3"
cp "$REPO/hooks/registry-lib.sh" "$GROKBOT_HOOKS_DIR/"
DBX="$GROKBOT_HOOKS_DIR/threads.sqlite"
REG() { sqlite3 -readonly "$DBX" "$1"; }

# curl stub: records every payload.
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then printf '%s\n' "$2" | jq -c . >> "$CALLS"; break; fi
  shift
done
printf 200
STUB
# Fake T3 CLI: `t3 thread show <id> --json --messages 0`, from $FAKE_T3/<id>.json.
cat > "$TMP/bin/t3" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_T3/cli-calls"
[ "$1 $2" = "thread show" ] || exit 64
if [ -f "$FAKE_T3/DOWN" ]; then echo "server not running" >&2; exit 2; fi
if [ -f "$FAKE_T3/$3.json" ]; then cat "$FAKE_T3/$3.json"; exit 0; fi
echo "Thread $3 is no longer available." >&2; exit 1
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/t3"
export PATH="$TMP/bin:$PATH"
touch "$CALLS"

# Fake T3 database with the one table the lookup reads.
sqlite3 "$GROKBOT_T3_DB" "CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT, project_id TEXT, title TEXT, updated_at TEXT, archived_at TEXT, deleted_at TEXT, payload_json TEXT);"
db_thread() { # id worktree title [updated_at] [deleted_at]
  local del=NULL
  [ -z "${5:-}" ] || del="'$5'"
  sqlite3 "$GROKBOT_T3_DB" "INSERT INTO orchestration_v2_projection_threads VALUES('$1','proj-db','$3','${4:-2026-11-05T10:00:00Z}',NULL,$del,json_object('worktreePath','$2'));"
}
fixture() { # id worktree title [archived] [settled]
  jq -n --arg id "$1" --arg wt "$2" --arg title "$3" --argjson a "${4:-false}" --argjson s "${5:-false}" \
    '{thread:{threadId:$id,projectId:"proj-cli",title:$title,branch:"b",worktreePath:$wt,archived:$a,settled:$s,status:"idle",linkedPullRequest:null,pullRequests:[]}}' > "$FAKE_T3/$1.json"
}

mkworktree() { # name bot -> creates a git repo with a marker, prints its real path
  mkdir -p "$TMP/$1"
  git -C "$TMP/$1" init -q -b "br-$1"
  printf '%s\n' "$2" > "$TMP/$1/.grokbot"
  printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/$2.env"
  (cd "$TMP/$1" && pwd -P)
}
W1="$(mkworktree w1 test)"; W2="$(mkworktree w2 test)"; W3="$(mkworktree w3 test)"; WO="$(mkworktree wo other)"
touch "$GROKBOT_HOOKS_DIR/notify.log"

hook() { # <harness> <worktree> <status> [env thread id] [extra json]: runs the hook, waits for its worker
  local before i after
  before=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
  printf '%s' "$3" > "$2/.grokbot-status"
  jq -n --arg cwd "$2" --arg sid "sess-$RANDOM" '{cwd:$cwd,session_id:$sid,last_assistant_message:"hello"}' |
    env ${4:+T3CODE_THREAD_ID="$4"} bash "$REPO/hooks/notify.sh" "$1"
  for ((i=0; i<500; i++)); do
    after=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
    [ "$after" -gt "$before" ] && return
    sleep 0.02
  done
  echo 'FAIL: worker did not finish' >&2; exit 1
}
sweep() {
  local before i after
  before=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
  bash "$REPO/hooks/notify.sh" --sweep
  for ((i=0; i<500; i++)); do
    after=$(grep -c worker-complete "$GROKBOT_HOOKS_DIR/notify.log" || true)
    [ "$after" -gt "$before" ] && return
    sleep 0.02
  done
  echo 'FAIL: sweep did not finish' >&2; exit 1
}
last() { tail -n 1 "$CALLS" | jq -r "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
cli_calls() { wc -l < "$FAKE_T3/cli-calls" 2>/dev/null | tr -d ' ' || echo 0; }
touch "$FAKE_T3/cli-calls"

# ---- 1. Claude: thread id from T3CODE_THREAD_ID, confirmed by the CLI -----------------------------
fixture tid1 "$W1" "Fix the login redirect"
hook claude "$W1" 'done PR https://example.test/pr/1' tid1
expect "$(last .thread_id)" tid1 'env thread id'
expect "$(last .thread_title)" 'Fix the login redirect' 'title'
expect "$(last .project_id)" proj-cli 'project'
expect "$(last .thread_source)" env 'source'
expect "$(last .branch)" br-w1 'branch still reported'
expect "$(last '.my_open_threads[0]')" 'tid1|done|br-w1|Fix the login redirect' 'summary line'
expect "$(last .my_open_threads_more)" 0 'summary overflow'
# Existing payload keys are all still there and unchanged in kind.
for k in event bot harness worktree branch status last_message ended_at cwd session_id transcript_path; do
  last "has(\"$k\")" | grep -q true || fail "legacy key $k missing"
done
expect "$(last .event)" t3_turn_ended 'event'
expect "$(REG "SELECT state||'|'||status_word||'|'||thread_id||'|'||thread_source FROM threads WHERE worktree='$W1'")" 'done|done|tid1|env' 'registry row'
[ "$(stat -f %Lp "$DBX")" = 600 ] || fail "registry file mode $(stat -f %Lp "$DBX")"

# ---- 2. A fresh row is not re-checked on every turn (CLI is asked once per 10 minutes) -----------
n=$(cli_calls)
hook claude "$W1" 'milestone more work' tid1
expect "$(cli_calls)" "$n" 'CLI calls on a fresh row'
expect "$(last .status)" 'milestone more work' 'status sent'
expect "$(REG "SELECT state FROM threads WHERE worktree='$W1'")" open 'done -> open on new status'

# ---- 3. Codex: no env var, thread id from the T3 database by worktree path ----------------------
db_thread tid2 "$W2" 'Add export button'
fixture tid2 "$W2" 'Add export button'
hook codex "$W2" 'idle'
expect "$(last .thread_id)" tid2 'db thread id'
expect "$(last .thread_source)" t3db 'db source'
expect "$(last .thread_title)" 'Add export button' 'db title (CLI confirmed)'
# Newest thread wins when a worktree was reused; deleted threads are ignored.
db_thread tid2b "$W2" 'Newer thread' '2026-11-05T12:00:00Z'
db_thread tid2c "$W2" 'Deleted thread' '2026-11-05T13:00:00Z' '2026-11-05T13:01:00Z'
fixture tid2b "$W2" 'Newer thread'
hook codex "$W2" 'needs_input which format?'
expect "$(last .thread_id)" tid2b 'newest live thread for the worktree'

# ---- 4. A thread whose CLI record says another worktree is rejected -------------------------------
fixture tid-elsewhere "$TMP/somewhere-else" 'Other'
hook claude "$W2" 'idle again' tid-elsewhere
expect "$(last .thread_id)" tid2b 'env id for another worktree ignored, db id used'
expect "$(last .thread_source)" t3db 'falls back to db'

# ---- 5. T3 CLI down: ids still resolve (unchecked), CLI is skipped for a while -------------------
touch "$FAKE_T3/DOWN"
db_thread tid3 "$W3" 'Third thread'
hook codex "$W3" 'idle'
expect "$(last .thread_id)" tid3 'unchecked db id'
expect "$(last .thread_title)" 'Third thread' 'db title when CLI is down'
expect "$(last .project_id)" proj-db 'db project'
[ -f "$GROKBOT_STATE_DIR/t3cli.fail" ] || fail 'CLI failure marker missing'
n=$(cli_calls)
hook codex "$W3" 'idle two'
expect "$(cli_calls)" "$n" 'CLI skipped while it is failing'
rm -f "$FAKE_T3/DOWN" "$GROKBOT_STATE_DIR/t3cli.fail"
fixture tid3 "$W3" 'Third thread'

# ---- 6. Nothing resolves: the callback still goes out, with empty thread fields -------------------
WN="$(mkworktree wn test)"
hook codex "$WN" 'idle'
expect "$(last .thread_id)" '' 'unknown thread id'
expect "$(last .bot)" test 'bot still routed'
expect "$(last '.my_open_threads | map(select(startswith("-|"))) | length')" 1 'unresolved row listed with -'
expect "$(REG "SELECT count(*) FROM threads WHERE worktree='$WN' AND thread_id IS NULL")" 1 'unresolved row'

# ---- 7. Approval ping carries the thread id and leaves the row's status alone ---------------------
before=$(wc -l < "$CALLS" | tr -d ' ')
jq -n --arg cwd "$W1" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' | env T3CODE_THREAD_ID=tid1 bash "$REPO/hooks/notify.sh" codex-permission
for ((i=0; i<500; i++)); do [ "$(wc -l < "$CALLS" | tr -d ' ')" -gt "$before" ] && break; sleep 0.02; done
expect "$(last .thread_id)" tid1 'approval thread id'
expect "$(last .status)" 'needs_input approval Bash: ls' 'approval status'
expect "$(REG "SELECT status_word FROM threads WHERE worktree='$W1'")" milestone 'approval does not rewrite the stored status'

# ---- 8. Summary: only this bot, open/done/worktree_missing, newest first, capped -------------------
hook claude "$WO" 'idle' ''
expect "$(last '.my_open_threads | length')" 1 'other bot has its own list'
expect "$(last '.my_open_threads[0] | startswith("-|idle|br-wo")')" true 'other bot line'
hook claude "$W1" 'done again' tid1
n=$(last '.my_open_threads | length')
[ "$n" -ge 4 ] || fail "expected at least 4 test-bot lines, got $n"
expect "$(last '.my_open_threads[0] | startswith("tid1|done|")')" true 'newest first'
GROKBOT_SUMMARY_MAX=2 hook claude "$W1" 'done once more' tid1
expect "$(last '.my_open_threads | length')" 2 'cap'
[ "$(last .my_open_threads_more)" -ge 2 ] || fail 'overflow count'
GROKBOT_SUMMARY_MAX=0 hook claude "$W1" 'done last time' tid1
expect "$(last '.my_open_threads | length')" 0 'summary off'
expect "$(last .thread_id)" tid1 'thread id still sent with summary off'

# ---- 9. Settled / archived / removed rows leave the summary after a refresh ----------------------
old=$(( $(date +%s) - 7200 ))
REG_SQL() { sqlite3 "$DBX" "$1"; }
fixture tid3 "$W3" 'Third thread' false true      # settled in T3
REG_SQL "UPDATE threads SET enriched_at=$old"
sweep
expect "$(REG "SELECT state FROM threads WHERE worktree='$W3'")" settled 'settled'
rm -f "$FAKE_T3/tid2b.json"                          # deleted in T3
REG_SQL "UPDATE threads SET enriched_at=$old"
sweep
expect "$(REG "SELECT state FROM threads WHERE worktree='$W2'")" removed 'removed'
hook claude "$W1" 'idle' tid1
last '.my_open_threads | map(startswith("tid3|") or startswith("tid2b|")) | any' | grep -q false || fail 'settled/removed rows still listed'
# Final rows are pruned after 30 days.
REG_SQL "UPDATE threads SET final_since=1 WHERE worktree='$W3'"
sweep
expect "$(REG "SELECT count(*) FROM threads WHERE worktree='$W3'")" 0 'pruned'
# A pruned row stays pruned: the sweep only updates rows it knows.
sweep
expect "$(REG "SELECT count(*) FROM threads WHERE worktree='$W3'")" 0 'pruned row not recreated by sweep'

# ---- 10. Untrusted text cannot break the SQL ----------------------------------------------------
fixture tid1 "$W1" "Evil'); DROP TABLE threads;-- |pipe"
REG_SQL "UPDATE threads SET enriched_at=$old WHERE worktree='$W1'"
hook claude "$W1" $'needs_input it\'s a "question"\nsecond line; DROP TABLE threads;' tid1
expect "$(REG "SELECT count(*) FROM threads WHERE worktree='$W1'")" 1 'table survived'
expect "$(last .thread_title)" "Evil'); DROP TABLE threads;-- /pipe" 'title kept, | replaced'
expect "$(REG "SELECT status_word FROM threads WHERE worktree='$W1'")" needs_input 'status word'
last '.my_open_threads | map(select(startswith("tid1|"))) | .[0] | split("|") | length' | grep -qx 4 || fail 'summary line has more than 4 fields'

# ---- 11. markers.tsv migration; worktree_missing --------------------------------------------------
rm -rf "$GROKBOT_HOOKS_DIR/threads.sqlite"*
rm -rf "$GROKBOT_STATE_DIR"
printf '%s\ttest\n%s\ttest\n' "$W1" "$TMP/gone-worktree" > "$GROKBOT_HOOKS_DIR/markers.tsv"
sweep
expect "$(REG "SELECT state FROM threads WHERE worktree='$TMP/gone-worktree'")" worktree_missing 'missing worktree row'
expect "$(REG "SELECT bot FROM threads WHERE worktree='$W1'")" test 'migrated row'
expect "$(REG "SELECT v IS NOT NULL FROM meta WHERE k='migrated_markers'")" 1 'migration flag'
expect "$(REG "SELECT count(*) FROM threads")" 2 'rows after migration (no duplicates)'
sweep
expect "$(REG "SELECT count(*) FROM threads")" 2 'migration runs once'
# The sweep resolves the migrated row's thread through the database (tid-w1 lives in the fake DB).
db_thread tidw1 "$W1" 'Migrated thread'; fixture tidw1 "$W1" 'Migrated thread'
sweep
expect "$(REG "SELECT thread_id FROM threads WHERE worktree='$W1'")" tidw1 'sweep fills in missing thread ids'
# worktree_missing pings carry whatever the registry knows about the worktree.
expect "$(last .status | cut -c1-16)" 'worktree_missing' 'missing worktree ping'

# ---- 12. Switches: registry off, database lookup off ----------------------------------------------
rm -rf "$GROKBOT_HOOKS_DIR/threads.sqlite"* "$GROKBOT_STATE_DIR"
GROKBOT_REGISTRY=0 hook claude "$W1" 'idle' tid1
[ ! -e "$DBX" ] || fail 'registry file created with GROKBOT_REGISTRY=0'
expect "$(last .thread_id)" '' 'no thread id with registry off'
expect "$(last '.my_open_threads | length')" 0 'no summary with registry off'
GROKBOT_T3_DB_LOOKUP=0 hook codex "$W1" 'idle'
expect "$(last .thread_id)" '' 'no db lookup when disabled'
# A config file value works like the environment (env still wins).
printf 'GROKBOT_SUMMARY_MAX=1\n' > "$GROKBOT_HOOKS_DIR/config"
cp "$REPO/hooks/config-lib.sh" "$GROKBOT_HOOKS_DIR/config-lib.sh"
hook claude "$W1" 'idle config' tid1
expect "$(last '.my_open_threads | length')" 1 'config file summary cap'
rm -f "$GROKBOT_HOOKS_DIR/config" "$GROKBOT_HOOKS_DIR/config-lib.sh"

# ---- 12b. Review findings: octal setting, rejected cached id, unresolvable rows do not starve others --
GROKBOT_SUMMARY_MAX=08 hook claude "$W1" 'idle octal' tid1
expect "$(last .event)" t3_turn_ended '08 summary setting must not stop the callback'
[ "$(last '.my_open_threads | length')" -le 8 ] || fail 'summary cap 08'
GROKBOT_SUMMARY_MAX=99999999999999999999 hook claude "$W1" 'idle huge' tid1
[ "$(last '.my_open_threads | length')" -le 20 ] || fail 'summary hard cap'
# A cached id that T3 now places in another worktree is dropped, not sent.
fixture tid1 "$TMP/moved-elsewhere" 'Moved'
REG_SQL "UPDATE threads SET enriched_at=$old WHERE worktree='$W1'"
GROKBOT_T3_DB_LOOKUP=0 hook codex "$W1" 'idle after move'
expect "$(last .thread_id)" '' 'rejected cached id not in callback'
expect "$(REG "SELECT thread_id IS NULL FROM threads WHERE worktree='$W1'")" 1 'rejected cached id cleared'
fixture tid1 "$W1" 'Back again'
# Hook-driven refreshes look at 3 unresolved rows per run: the ones already tried go to the back.
WA="$(mkworktree wa test)"; WB="$(mkworktree wb test)"; WC="$(mkworktree wc test)"; WL="$(mkworktree wl test)"
for w in "$WL" "$WA" "$WB" "$WC"; do GROKBOT_T3_DB_LOOKUP=0 hook codex "$w" 'idle'; done
db_thread tidL "$WL" 'Late thread'; fixture tidL "$WL" 'Late thread'
hook claude "$W1" 'idle r1' tid1
hook claude "$W1" 'idle r2' tid1
expect "$(REG "SELECT thread_id FROM threads WHERE worktree='$WL'")" tidL 'older unresolved row eventually resolved'

# ---- 13. notify.sh without registry-lib.sh still works (partial install) -------------------------
mkdir -p "$TMP/partial"
cp "$REPO/hooks/notify.sh" "$TMP/partial/"
before=$(wc -l < "$CALLS" | tr -d ' ')
printf 'idle partial' > "$W1/.grokbot-status"
jq -n --arg cwd "$W1" '{cwd:$cwd}' | GROKBOT_HOOKS_DIR="$TMP/partial" GROKBOT_STATE_DIR="$TMP/partial/state" bash "$TMP/partial/notify.sh" claude
cp "$GROKBOT_HOOKS_DIR/test.env" "$TMP/partial/test.env"
jq -n --arg cwd "$W1" '{cwd:$cwd}' | GROKBOT_HOOKS_DIR="$TMP/partial" GROKBOT_STATE_DIR="$TMP/partial/state" bash "$TMP/partial/notify.sh" claude
for ((i=0; i<500; i++)); do [ "$(wc -l < "$CALLS" | tr -d ' ')" -gt "$before" ] && break; sleep 0.02; done
expect "$(last .thread_id)" '' 'partial install: empty thread id'
expect "$(last '.my_open_threads | length')" 0 'partial install: empty summary'
[ ! -e "$TMP/partial/threads.sqlite" ] || fail 'partial install created a registry'

echo 'PASS: thread registry (env id, db lookup, CLI check/mismatch/down/breaker, fail-soft, approval, summary scope/cap, settled/removed/prune, SQL safety, markers.tsv migration, switches, partial install)'
