#!/bin/bash
# shellcheck disable=SC2015,SC2016 # the A && B || fail lines are checks, not if/else; single quotes keep $ literal
# Routing for worktrees without a marker (delegated sub-threads) and the sweep over T3's pending
# approvals. Uses a fake T3 database and a fake `t3` command in a temporary directory; stub curl.
# Never touches the real T3, ~/.grokbot-hooks or any Claude/Codex config.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset T3CODE_THREAD_ID T3CODE_CLI_PATH T3CODE_HOME GROKBOT_REGISTRY GROKBOT_SUMMARY_MAX GROKBOT_ROUTE_PARENT GROKBOT_ROUTE_PROJECT GROKBOT_APPROVAL_MINUTES
export HOME="$TMP/home" GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state" CALLS="$TMP/calls"
export FAKE_T3="$TMP/fake-t3" GROKBOT_T3_CLI="$TMP/bin/t3" GROKBOT_T3_DB="$TMP/t3.sqlite"
mkdir -p "$HOME" "$GROKBOT_HOOKS_DIR" "$TMP/bin" "$FAKE_T3"
cp "$REPO/hooks/registry-lib.sh" "$GROKBOT_HOOKS_DIR/"
LOGF="$GROKBOT_HOOKS_DIR/notify.log"
touch "$LOGF" "$CALLS"
fail() { echo "FAIL: $*" >&2; tail -n 8 "$LOGF" >&2; exit 1; }

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then
    [ ! -f "$FAKE_T3/CURL_FAIL" ] || { printf 500; exit 0; }
    printf '%s\n' "$2" | jq -c . >> "$CALLS"; break
  fi
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

# Fake T3 database with the columns the hooks read.
sqlite3 "$GROKBOT_T3_DB" "
CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT, updated_at TEXT, archived_at TEXT, deleted_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_runtime_requests(runtime_request_id TEXT PRIMARY KEY, thread_id TEXT, kind TEXT, status TEXT, created_at TEXT, resolved_at TEXT);"
# db_thread <id> <project> <title> <worktree> <parent|-> [createdBy] [source] [archived]
db_thread() {
  local parent='null' arch=NULL
  [ "$5" = - ] || parent="\"$5\""
  [ -z "${8:-}" ] || arch="'2026-11-10T00:00:00Z'"
  sqlite3 "$GROKBOT_T3_DB" "INSERT INTO orchestration_v2_projection_threads VALUES('$1','$2','$3','2026-11-10T10:00:00Z',$arch,NULL,
    json('{\"worktreePath\":\"$4\",\"createdBy\":\"${6:-agent}\",\"creationSource\":\"${7:-mcp}\",\"lineage\":{\"parentThreadId\":$parent}}'));"
}
# db_request <id> <thread> <kind> <status> <minutes ago>
db_request() {
  sqlite3 "$GROKBOT_T3_DB" "INSERT INTO orchestration_v2_projection_runtime_requests VALUES('$1','$2','$3','$4',strftime('%Y-%m-%dT%H:%M:%fZ','now','-$5 minutes'),NULL);"
}
mkwt() { mkdir -p "$TMP/$1"; git -C "$TMP/$1" init -q -b "br-$1"; (cd "$TMP/$1" && pwd -P); }
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/orcy.env"
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/tooly.env"

# The orchestrator (marked, bot orcy) and two builders it delegated; a grandchild; strangers.
WP="$(mkwt parent)"; printf 'orcy\n' > "$WP/.grokbot"
WA="$(mkwt builder-a)"; WB="$(mkwt builder-b)"; WG="$(mkwt grandchild)"; WU="$(mkwt user-thread)"; WX="$(mkwt lone-agent)"; WN="$(mkwt not-t3)"
db_thread parent proj-1 'Orchestrator' "$WP" -
db_thread builder-a proj-1 'Builder A: permissions' "$WA" parent
db_thread builder-b proj-1 'Builder B: chat UI' "$WB" parent
db_thread grandchild proj-1 'Grandchild' "$WG" builder-a
db_thread user-thread proj-1 'My own thread' "$WU" - user web
db_thread lone-agent proj-1 'Agent thread without parent' "$WX" - agent mcp
printf '%s\torcy\n' "$WP" > "$GROKBOT_HOOKS_DIR/markers.tsv"

# A ping ends with worker-complete; a prompt that cannot be routed ends with a no-marker line.
ends() { echo $(( $(grep -c 'worker-complete\|no-marker' "$LOGF" || true) )); }
waitdone() { # <ends() before>
  local i
  for ((i=0; i<500; i++)); do
    [ "$(ends)" -gt "$1" ] && return
    sleep 0.02
  done
  fail 'worker did not finish'
}
approve() { # <cwd> [env thread id] [mode]: a Claude permission prompt in that cwd
  local before
  before=$(ends)
  jq -n --arg cwd "$1" '{cwd:$cwd,session_id:"s1",hook_event_name:"Notification",notification_type:"permission_prompt",message:"Claude needs your permission to use Bash"}' |
    env ${2:+T3CODE_THREAD_ID="$2"} bash "$REPO/hooks/notify.sh" "${3:-claude-notify}"
  waitdone "$before"
}
sweep() { bash "$REPO/hooks/notify.sh" --sweep; }
count() { [ "$(wc -l < "$CALLS" | tr -d ' ')" = "$1" ] || fail "expected $1 sends, got $(wc -l < "$CALLS" | tr -d ' '): $(cat "$CALLS")"; }
last() { tail -n 1 "$CALLS" | jq -r "$1"; }

# --- 1. Approval prompt in a delegated sub-thread (env id, like Claude Code in T3): parent's bot. ---
approve "$WA" builder-a
count 1
[ "$(last .bot)" = orcy ] || fail "bot: $(last .bot)"
[ "$(last .route)" = parent ] || fail "route: $(last .route)"
[ "$(last .sub_thread_id)" = builder-a ] && [ "$(last .sub_thread_title)" = 'Builder A: permissions' ] || fail "sub thread: $(last .sub_thread_id) $(last .sub_thread_title)"
[ "$(last .parent_thread_id)" = parent ] && [ "$(last .parent_thread_title)" = Orchestrator ] && [ "$(last .parent_worktree)" = "$WP" ] || fail "parent fields: $(tail -n1 "$CALLS")"
[ "$(last .thread_id)" = builder-a ] || fail "thread_id is the blocked thread: $(last .thread_id)"
[ "$(last .worktree)" = "$WA" ] || fail "worktree: $(last .worktree)"
case "$(last .status)" in 'needs_input approval '*) ;; *) fail "status: $(last .status)" ;; esac
[ ! -f "$WA/.grokbot" ] || fail 'the routed worktree must stay marker-less'
[ ! -f "$GROKBOT_HOOKS_DIR/threads.sqlite" ] || [ "$(sqlite3 "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT count(*) FROM threads WHERE worktree='$WA'")" = 0 ] || fail 'routed worktree got a registry row'
grep -q "claude-notify route=parent bot=orcy sub=builder-a parent=parent " "$LOGF" || fail 'route not logged'

# --- 2. Same without the env id (Codex): found by worktree path. ---
approve "$WB" '' codex-permission
count 2
[ "$(last .route)" = parent ] && [ "$(last .sub_thread_id)" = builder-b ] || fail "codex route: $(tail -n1 "$CALLS")"
# From a subdirectory of the worktree too.
mkdir -p "$WB/sub/dir"
approve "$WB/sub/dir" builder-b
count 3
[ "$(last .sub_thread_id)" = builder-b ] || fail "subdir: $(tail -n1 "$CALLS")"

# --- 3. A grandchild walks up two levels to the marked ancestor. ---
approve "$WG" grandchild
count 4
[ "$(last .parent_thread_id)" = parent ] && [ "$(last .sub_thread_id)" = grandchild ] || fail "grandchild: $(tail -n1 "$CALLS")"

# --- 4. Not routable: a thread of your own, a folder T3 does not know. Logged, nothing sent. ---
approve "$WU" user-thread
approve "$WN"
count 4
grep -q "claude-notify no-marker $WU" "$LOGF" && grep -q "claude-notify no-marker $WN" "$LOGF" || fail 'no-marker lines missing'

jq -n --arg wt "$WP" '{thread:{threadId:"parent",projectId:"proj-1",title:"Orchestrator",worktreePath:$wt,archived:false}}' > "$FAKE_T3/parent.json"
# --- 5. Project fallback: an agent-launched thread with no parent goes to the project's bot, and
#        only that kind. The registry learns the project from a marked turn. ---
approve "$WX" lone-agent
count 4                                  # no registry row for proj-1 yet: nothing to fall back to
jq -n --arg cwd "$WP" '{cwd:$cwd,session_id:"s0",last_assistant_message:"x"}' | env T3CODE_THREAD_ID=parent bash "$REPO/hooks/notify.sh" claude
for ((i=0; i<500; i++)); do [ "$(sqlite3 "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT project_id FROM threads WHERE worktree='$WP'" 2>/dev/null)" = proj-1 ] && break; sleep 0.02; done
[ "$(sqlite3 "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT project_id FROM threads WHERE worktree='$WP'")" = proj-1 ] || fail 'registry did not learn the project'
sleep 0.3
: > "$CALLS"
approve "$WX" lone-agent
count 1
[ "$(last .route)" = project ] && [ "$(last .bot)" = orcy ] && [ "$(last .sub_thread_id)" = lone-agent ] && [ "$(last .parent_thread_id)" = '' ] || fail "project route: $(tail -n1 "$CALLS")"
approve "$WU" user-thread                # a thread you started yourself never uses the project route
count 1
: > "$CALLS"
GROKBOT_ROUTE_PROJECT=0 approve "$WX" lone-agent
count 0
GROKBOT_ROUTE_PARENT=0 approve "$WA" builder-a
count 1                                  # parent route off: falls to the project (builder-a is agent/mcp)
[ "$(last .route)" = project ] || fail "parent off: $(tail -n1 "$CALLS")"
: > "$CALLS"
GROKBOT_ROUTE_PARENT=0 GROKBOT_ROUTE_PROJECT=0 approve "$WA" builder-a
count 0

# --- 6. T3's database unavailable: the t3 CLI answers instead (by id). ---
mv "$GROKBOT_T3_DB" "$GROKBOT_T3_DB.off"
jq -n '{thread:{threadId:"builder-a",projectId:"proj-1",title:"Builder A: permissions",worktreePath:"x",parentThreadId:"parent",createdBy:"agent",creationSource:"mcp",archived:false}}' > "$FAKE_T3/builder-a.json"
jq -n --arg wt "$WP" '{thread:{threadId:"parent",projectId:"proj-1",title:"Orchestrator",worktreePath:$wt,archived:false}}' > "$FAKE_T3/parent.json"
rm -rf "$GROKBOT_STATE_DIR"             # a first hook may run before any state directory exists
approve "$WA" builder-a
count 1
[ "$(last .route)" = parent ] && [ "$(last .parent_thread_id)" = parent ] || fail "cli fallback: $(tail -n1 "$CALLS")"
# A dead server trips the same breaker the registry uses, so lookups stop costing 8 seconds each.
touch "$FAKE_T3/DOWN"
approve "$WA" builder-a
count 1                                  # (nothing new was sent; the count is the earlier ping)
[ -f "$GROKBOT_STATE_DIR/t3cli.fail" ] || fail 'CLI failure did not set the breaker'
rm -f "$FAKE_T3/DOWN" "$GROKBOT_STATE_DIR/t3cli.fail"
mv "$GROKBOT_T3_DB.off" "$GROKBOT_T3_DB"
: > "$CALLS"

# --- 7. Sweep over T3's pending approvals. ---
rm -rf "$GROKBOT_STATE_DIR/approvals"
db_request req-young builder-a command pending 3        # younger than 10 minutes: not yet
db_request req-resolved builder-b command resolved 40
db_request req-ancient builder-b command pending 4000   # more than 48 hours: ignore
db_request req-a builder-a command pending 25
db_request req-g grandchild user_input pending 15
db_request req-user user-thread command pending 30     # unroutable: logged once, never sent
db_request req-marked parent command pending 12         # the marked thread's own prompt: reminded too
sweep
count 3
jq -s -e 'map(.status) | (index("stalled 25m approval_pending command") != null) and (index("stalled 15m approval_pending user_input") != null) and (index("stalled 12m approval_pending command") != null)' "$CALLS" >/dev/null || fail "sweep statuses: $(jq -r .status "$CALLS" | tr '\n' ';')"
jq -s -e 'map(select(.thread_id == "builder-a"))[0] | .bot == "orcy" and .route == "parent" and .sub_thread_id == "builder-a" and .parent_thread_id == "parent" and .harness == "sweep" and .worktree == "'"$WA"'"' "$CALLS" >/dev/null || fail "sweep builder payload: $(cat "$CALLS")"
jq -s -e 'map(select(.thread_id == "parent"))[0] | .route == "marker" and .sub_thread_id == "" and .parent_thread_id == ""' "$CALLS" >/dev/null || fail "sweep marked payload: $(cat "$CALLS")"
grep -q 'no-route approval thread=user-thread' "$LOGF" || fail 'no-route not logged'
sweep; sweep
count 3                                                 # once per request
db_request req-new builder-b command pending 11
sweep
count 4
[ "$(last .thread_id)" = builder-b ] || fail "new request: $(tail -n1 "$CALLS")"
# The sweep must not disturb a marked worktree's own stall state.
[ -z "$(find "$GROKBOT_STATE_DIR" -maxdepth 1 -name '*.stalled' -print 2>/dev/null)" ] || fail 'approval sweep wrote a stall marker'

# --- 8. A failed send is retried by later sweeps, three attempts at most; no webhook is final. ---
: > "$CALLS"
db_request req-retry builder-a command pending 20
touch "$FAKE_T3/CURL_FAIL"
sweep; sweep; sweep; sweep
rm -f "$FAKE_T3/CURL_FAIL"
sweep
count 0                                                 # three failures used up the attempts
[ "$(cat "$GROKBOT_STATE_DIR/approvals/$(printf '%s' req-retry | shasum -a 256 | awk '{print $1}').tries")" = 3 ] || fail 'attempt count'
db_request req-retry2 builder-a command pending 20
touch "$FAKE_T3/CURL_FAIL"; sweep; rm -f "$FAKE_T3/CURL_FAIL"
sweep
count 1                                                 # one failure, then it goes through
[ "$(last .status)" = "stalled 20m approval_pending command" ] || fail "retry: $(last .status)"

# --- 9. Switches: GROKBOT_APPROVAL_MINUTES=0 turns the sweep part off; an archived thread is skipped. ---
: > "$CALLS"
db_request req-off builder-a command pending 40
GROKBOT_APPROVAL_MINUTES=0 sweep
count 0
db_thread archived-one proj-1 'Archived' "$TMP/gone" parent agent mcp 1
db_request req-arch archived-one command pending 40
sweep
count 1                                                 # req-off now goes; the archived thread's does not
[ "$(last .thread_id)" = builder-a ] || fail "archived: $(tail -n1 "$CALLS")"

# --- 9b. More pending requests than one query returns or one run sends: all get through, 5 per run. ---
: > "$CALLS"
for i in $(seq 1 25); do db_request "req-many-$i" builder-b command pending "$((100 + i))"; done
sweep; count 5
sweep; sweep; sweep; sweep
count 25
sweep; count 25

# --- 9c. A failed lookup is not a verdict: retried (bounded), and routed once T3 knows the ancestor. ---
: > "$CALLS"
db_thread orphan proj-1 'Orphan' "$TMP/orphan" ghost user web
db_request req-orphan orphan command pending 30
sweep
count 0
grep -q 'route-lookup-failed approval thread=orphan' "$LOGF" || fail 'failed lookup not logged'
[ ! -f "$GROKBOT_STATE_DIR/approvals/$(printf '%s' req-orphan | shasum -a 256 | awk '{print $1}')" ] || fail 'failed lookup was made final'
db_thread ghost proj-1 'Ghost orchestrator' "$WP" -
sweep
count 1
[ "$(last .thread_id)" = orphan ] && [ "$(last .parent_thread_id)" = ghost ] || fail "orphan after ancestor appeared: $(tail -n1 "$CALLS")"

# --- 9d. Titles with line breaks and separator characters keep their fields intact. ---
: > "$CALLS"
sqlite3 "$GROKBOT_T3_DB" "INSERT INTO orchestration_v2_projection_threads VALUES('multi','proj-1','Line one'||char(10)||'line two'||char(31)||'x','2026-11-10T10:00:00Z',NULL,NULL,
  json('{\"worktreePath\":\"$TMP/multi\",\"createdBy\":\"agent\",\"creationSource\":\"mcp\",\"lineage\":{\"parentThreadId\":\"multip\"}}'));
  INSERT INTO orchestration_v2_projection_threads VALUES('multip','proj-1','Parent'||char(10)||'multi','2026-11-10T10:00:00Z',NULL,NULL,
  json('{\"worktreePath\":\"$WP\",\"createdBy\":\"agent\",\"creationSource\":\"mcp\",\"lineage\":{\"parentThreadId\":null}}'));"
approve "$TMP/multi" multi
count 1
[ "$(last .route)" = parent ] && [ "$(last .parent_thread_id)" = multip ] && [ "$(last .parent_worktree)" = "$WP" ] || fail "multiline titles: $(tail -n1 "$CALLS")"
[ "$(last .sub_thread_title)" = 'Line one line two x' ] && [ "$(last .parent_thread_title)" = 'Parent multi' ] || fail "multiline title text: $(last .sub_thread_title) / $(last .parent_thread_title)"

# --- 9e. GROKBOT_REGISTRY=0 turns routing and the approvals sweep off: no thread ids leave the machine. ---
: > "$CALLS"
db_request req-regoff builder-a command pending 40
GROKBOT_REGISTRY=0 approve "$WA" builder-a
GROKBOT_REGISTRY=0 sweep
count 0
sweep
count 1
[ "$(last .thread_id)" = builder-a ] || fail "after registry back on: $(tail -n1 "$CALLS")"

# --- 9f. More than one page of handled requests must not hide a newer one. ---
: > "$CALLS"
sqlite3 "$GROKBOT_T3_DB" "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 210)
  INSERT INTO orchestration_v2_projection_runtime_requests SELECT 'req-page-'||i, 'builder-b', 'command', 'pending', strftime('%Y-%m-%dT%H:%M:%fZ','now','-'||(2000+i)||' minutes'), NULL FROM n;"
mkdir -p "$GROKBOT_STATE_DIR/approvals"
for i in $(seq 1 210); do echo sent > "$GROKBOT_STATE_DIR/approvals/$(printf '%s' "req-page-$i" | shasum -a 256 | awk '{print $1}')"; done
db_request req-after-pages builder-b command pending 9.5
db_request req-after-pages2 builder-b command pending 11
sweep
count 1
[ "$(last .status)" = 'stalled 11m approval_pending command' ] || fail "request behind 210 handled ones: $(tail -n1 "$CALLS")"

# --- 9g. The project lookup failing is not a verdict either. ---
: > "$CALLS"
db_thread lone2 proj-1 'Another agent thread' "$TMP/lone2" - agent mcp
db_request req-lone2 lone2 command pending 30
chmod 000 "$GROKBOT_HOOKS_DIR/threads.sqlite"
sweep
chmod 600 "$GROKBOT_HOOKS_DIR/threads.sqlite"
count 0
grep -q 'route-lookup-failed approval thread=lone2' "$LOGF" || fail 'registry failure not treated as a failed lookup'
sweep
count 1
[ "$(last .route)" = project ] && [ "$(last .thread_id)" = lone2 ] || fail "lone2 after registry recovered: $(tail -n1 "$CALLS")"

# --- 10. Without registry-lib.sh nothing routes and nothing breaks. ---
: > "$CALLS"
mv "$GROKBOT_HOOKS_DIR/registry-lib.sh" "$GROKBOT_HOOKS_DIR/registry-lib.sh.off"
approve "$WA" builder-a
db_request req-nolib builder-a command pending 40
sweep
count 0
mv "$GROKBOT_HOOKS_DIR/registry-lib.sh.off" "$GROKBOT_HOOKS_DIR/registry-lib.sh"

echo 'PASS: routing of marker-less sub-threads (parent route, grandchild, Codex path lookup, project fallback, CLI fallback, switches) and the pending-approval sweep (age window, once per request, retries, archived, no-route)'
