#!/bin/bash
# shellcheck disable=SC2015,SC2016 # the A && B || fail lines are checks, not if/else; single quotes keep $ literal
# The sweep over removed worktrees: quiet when the removal was intentional (thread settled, archived or
# deleted; branch merged; PR merged or closed), a ping otherwise or when gh cannot answer.
# Real git repositories in a temporary directory; stub curl, t3 and gh. Never touches the real ones.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
unset T3CODE_THREAD_ID T3CODE_CLI_PATH T3CODE_HOME GROKBOT_REGISTRY GROKBOT_SUMMARY_MAX
export HOME="$TMP/home" GROKBOT_HOOKS_DIR="$TMP/hooks" GROKBOT_STATE_DIR="$TMP/state" CALLS="$TMP/calls"
export FAKE="$TMP/fake" GROKBOT_T3_CLI="$TMP/bin/t3" GROKBOT_T3_DB="$TMP/no-t3.sqlite"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@test.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@test.invalid
mkdir -p "$HOME" "$GROKBOT_HOOKS_DIR" "$TMP/bin" "$FAKE/pr"
cp "$REPO/hooks/registry-lib.sh" "$GROKBOT_HOOKS_DIR/"
printf 'GROKBOT_WEBHOOK_URL=http://test.invalid\n' > "$GROKBOT_HOOKS_DIR/test.env"
LOGF="$GROKBOT_HOOKS_DIR/notify.log"
MAP="$GROKBOT_HOOKS_DIR/markers.tsv"
touch "$LOGF" "$CALLS"
fail() { echo "FAIL: $*" >&2; tail -n 12 "$LOGF" >&2; exit 1; }

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then printf '%s\n' "$2" | jq -c . >> "$CALLS"; break; fi
  shift
done
printf 200
STUB
cat > "$TMP/bin/t3" <<'STUB'
#!/bin/bash
[ "$1 $2" = "thread show" ] || exit 64
if [ -f "$FAKE/T3_DOWN" ]; then echo "server not running" >&2; exit 2; fi
if [ -f "$FAKE/$3.json" ]; then cat "$FAKE/$3.json"; exit 0; fi
echo "Thread $3 is no longer available." >&2; exit 1
STUB
# gh pr list --head <branch>: answers from $FAKE/pr/<branch>, else an empty list.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
head=
while [ "$#" -gt 0 ]; do [ "$1" != --head ] || head="$2"; shift; done
echo "$head" >> "$FAKE/gh-calls"
[ ! -f "$FAKE/GH_FAIL" ] || exit 1
if [ -f "$FAKE/GH_HANG" ]; then trap '' ALRM; exec sleep 30; fi
cat "$FAKE/pr/$head" 2>/dev/null || echo '[]'
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/t3" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
touch "$FAKE/gh-calls"

M="$TMP/main-repo"
git init -q -b main "$M"
git -C "$M" commit -q --allow-empty -m start

# wait_done <count before>: a worker run ends with worker-complete.
wait_done() {
  local i
  for ((i=0; i<1500; i++)); do
    [ "$(grep -c worker-complete "$LOGF" || true)" -gt "$1" ] && return
    sleep 0.02
  done
  fail 'worker did not finish'
}
done_count() { grep -c worker-complete "$LOGF" || true; }
turn() { # <worktree> [thread id]: a finished turn in a marked worktree
  local before
  before=$(done_count)
  jq -n --arg cwd "$1" '{cwd:$cwd,session_id:"s",last_assistant_message:"hi"}' |
    env ${2:+T3CODE_THREAD_ID="$2"} bash "$REPO/hooks/notify.sh" claude
  wait_done "$before"
}
sweep() { local before; before=$(done_count); bash "$REPO/hooks/notify.sh" --sweep; wait_done "$before"; }
# new_wt <name> [commit]: a linked worktree on branch <name>, marked for bot "test", with one finished turn.
new_wt() {
  local wt="$TMP/wt-$1"
  git -C "$M" worktree add -q -b "$1" "$wt" main
  [ -z "${2:-}" ] || git -C "$wt" commit -q --allow-empty -m "work on $1"
  printf 'test\n' > "$wt/.grokbot"
  printf 'done %s' "$1" > "$wt/.grokbot-status"
  turn "$wt" "${3:-}"
}
remove_wt() { git -C "$M" worktree remove --force "$TMP/wt-$1"; }
pr() { # <branch> <state> [oid] [cross repository]
  jq -n --arg s "$2" --arg o "${3:-$(git -C "$M" rev-parse "$1")}" --argjson x "${4:-false}" \
    '[{state:$s,headRefOid:$o,isCrossRepository:$x}]' > "$FAKE/pr/$1"
}
thread() { # <id> <worktree name> <archived> <settled>
  jq -n --arg id "$1" --arg wt "$TMP/wt-$2" --argjson a "$3" --argjson s "$4" \
    '{thread:{threadId:$id,projectId:"p",title:$id,worktreePath:$wt,archived:$a,settled:$s,status:"idle"}}' > "$FAKE/$1.json"
}
sends() { wc -l < "$CALLS" | tr -d ' '; }
expect_sends() { [ "$(sends)" = "$1" ] || fail "$2: expected $1 sends, got $(sends): $(cat "$CALLS")"; }
gh_calls() { grep -cx "$1" "$FAKE/gh-calls" || true; }
mapped() { grep -c "^$TMP/wt-$1	" "$MAP" || true; }
dropped() { # <name> <reason pattern>
  [ "$(mapped "$1")" = 0 ] || fail "$1: still in markers.tsv"
  [ "$(grep -c "worktree_missing dropped ($2.*) $TMP/wt-$1\$" "$LOGF" || true)" = 1 ] || fail "$1: drop not logged once as '$2'"
}
reset() { : > "$CALLS"; : > "$FAKE/gh-calls"; }
pinged() { # <name>
  jq -s -e --arg wt "$TMP/wt-$1" 'any(.[]; .worktree == $wt and (.status | startswith("worktree_missing ")))' "$CALLS" >/dev/null || fail "$1: no worktree_missing ping"
  [ "$(mapped "$1")" = 1 ] || fail "$1: entry dropped although pinged"
}
state_of() { sqlite3 -readonly "$GROKBOT_HOOKS_DIR/threads.sqlite" "SELECT state FROM threads WHERE worktree='$TMP/wt-$1'"; }

# --- 1. Branch merged into main: quiet, dropped, logged once, gh not needed. ---
new_wt merged commit
git -C "$M" merge -q --no-ff -m 'merge merged' merged
reset
remove_wt merged
sweep; sweep
expect_sends 0 'merged branch'
dropped merged 'branch merged merged'
[ "$(gh_calls merged)" = 0 ] || fail 'merged branch: gh was asked'
[ "$(state_of merged)" = removed ] || fail "merged branch: registry state $(state_of merged)"

# The same path used again is a live entry again.
git -C "$M" worktree add -q "$TMP/wt-merged" merged
printf 'test\n' > "$TMP/wt-merged/.grokbot"
printf 'done again' > "$TMP/wt-merged/.grokbot-status"
turn "$TMP/wt-merged"
[ "$(state_of merged)" = 'done' ] && [ "$(mapped merged)" = 1 ] || fail "reused path: state $(state_of merged)"
remove_wt merged; sweep

# --- 2. A new branch with no commits is not "merged": no PR, so ping; asked and sent once. ---
new_wt fresh
reset
remove_wt fresh
sweep; sweep; sweep
expect_sends 1 'fresh branch'
pinged fresh
[ "$(gh_calls fresh)" = 1 ] || fail "fresh branch: gh calls $(gh_calls fresh)"

# --- 3. PR merged (squash) or closed: quiet. PR open: ping. ---
new_wt squashed commit; new_wt closed commit; new_wt open commit
pr squashed MERGED; pr closed CLOSED; pr open OPEN
reset
remove_wt squashed; remove_wt closed; remove_wt open
sweep; sweep
expect_sends 1 'PR states'
dropped squashed 'PR for squashed'
dropped closed 'PR for closed'
pinged open

# --- 4. An old PR under a reused branch name, or a fork's PR, does not cover this work. ---
new_wt reused commit; new_wt forked commit
pr reused MERGED 1111111111111111111111111111111111111111
pr forked MERGED '' true
reset
remove_wt reused; remove_wt forked
sweep
expect_sends 2 'foreign PRs'
pinged reused; pinged forked

# --- 5. Thread settled, archived or deleted: quiet. Thread open and no PR: ping. ---
thread t-settled settled false false; thread t-archived archived false false
thread t-deleted deleted false false; thread t-open live false false
new_wt settled commit t-settled; new_wt archived commit t-archived
new_wt deleted commit t-deleted; new_wt live commit t-open
thread t-settled settled false true; thread t-archived archived true false
rm "$FAKE/t-deleted.json"
reset
remove_wt settled; remove_wt archived; remove_wt deleted; remove_wt live
sweep
expect_sends 1 'thread states'
dropped settled 'thread settled'
dropped archived 'thread settled'
dropped deleted 'thread settled'
pinged live
[ "$(gh_calls settled)$(gh_calls archived)$(gh_calls deleted)" = 000 ] || fail 'closed threads: gh was asked'

# --- 6. gh fails or hangs: today's behaviour (ping). ---
new_wt ghfail commit; pr ghfail MERGED
reset
touch "$FAKE/GH_FAIL"
remove_wt ghfail
sweep
rm "$FAKE/GH_FAIL"
expect_sends 1 'gh failed'
pinged ghfail
grep -q "worktree_missing gh-failed rc=1 $TMP/wt-ghfail" "$LOGF" || fail 'gh failure not logged'
new_wt ghhang commit; pr ghhang MERGED
reset
touch "$FAKE/GH_HANG"
remove_wt ghhang
started=$(date +%s)
sweep
rm "$FAKE/GH_HANG"
[ "$(($(date +%s) - started))" -lt 25 ] || fail 'hanging gh was not killed'
expect_sends 1 'gh hung'
pinged ghhang

# --- 7. Only the marker is gone, the directory stays: today's behaviour. ---
new_wt kept commit; pr kept MERGED
reset
rm "$TMP/wt-kept/.grokbot"
sweep
expect_sends 1 'directory kept'
pinged kept
[ "$(gh_calls kept)" = 0 ] || fail 'directory kept: gh was asked'

# --- 8. A running turn delays a quiet drop until the turn is over (or a day old). ---
new_wt running commit; pr running MERGED
key="$(printf '%s' "$TMP/wt-running" | shasum -a 256 | awk '{print $1}')"
printf '%s000000\n' "$(($(date +%s) + 5))" > "$GROKBOT_STATE_DIR/$key.turn_started"
reset
remove_wt running
sweep
expect_sends 0 'running turn'
[ "$(mapped running)" = 1 ] || fail 'running turn: dropped too early'
printf '%s000000\n' "$(($(date +%s) - 90000))" > "$GROKBOT_STATE_DIR/$key.turn_started"
printf '0\n' > "$GROKBOT_STATE_DIR/$key.turn_ended"
sweep
expect_sends 0 'old turn'
dropped running 'PR for running'

# --- 8b. A branch reset away from the last seen commit does not hide that work. ---
new_wt rewound commit
reset
remove_wt rewound
git -C "$M" branch -f rewound "$(git -C "$M" rev-parse 'main^2')"   # an older, merged side commit
pr rewound MERGED
sweep
expect_sends 1 'reset branch'
pinged rewound

# --- 8c. Entries waiting for a running turn are not asked about again and do not block later ones. ---
for i in 1 2 3 4 5; do
  new_wt "wait$i" commit; pr "wait$i" MERGED
  key="$(printf '%s' "$TMP/wt-wait$i" | shasum -a 256 | awk '{print $1}')"
  printf '%s000000\n' "$(($(date +%s) + 5))" > "$GROKBOT_STATE_DIR/$key.turn_started"
done
new_wt behind commit; pr behind OPEN
reset
for i in 1 2 3 4 5; do remove_wt "wait$i"; done
remove_wt behind
sweep
expect_sends 0 'five waiting'
sweep; sweep
expect_sends 1 'entry behind the waiting ones'
pinged behind
[ "$(grep -c '^wait' "$FAKE/gh-calls")" = 5 ] || fail "waiting entries asked again: $(grep -c '^wait' "$FAKE/gh-calls")"

# --- 8d. Thread checks share the per-run limit. ---
for i in 1 2 3 4 5 6 7; do
  thread "t-many$i" "many$i" false false; new_wt "many$i" commit "t-many$i"; thread "t-many$i" "many$i" false true
done
reset
for i in 1 2 3 4 5 6 7; do remove_wt "many$i"; done
sweep
[ "$(grep -c "worktree_missing dropped (thread settled.*wt-many" "$LOGF")" = 5 ] || fail "thread checks in one run: $(grep -c 'dropped.*wt-many' "$LOGF")"
sweep
expect_sends 0 'settled backlog'
for i in 1 2 3 4 5 6 7; do dropped "many$i" 'thread settled'; done

# --- 9. A big cleanup: at most 5 gh calls per run, nothing pinged while it waits. ---
for i in 1 2 3 4 5 6 7; do new_wt "bulk$i" commit; pr "bulk$i" MERGED; done
reset
for i in 1 2 3 4 5 6 7; do remove_wt "bulk$i"; done
sweep
[ "$(grep -c '^bulk' "$FAKE/gh-calls")" = 5 ] || fail "bulk: $(grep -c '^bulk' "$FAKE/gh-calls") gh calls in one run"
sweep
expect_sends 0 'bulk cleanup'
for i in 1 2 3 4 5 6 7; do dropped "bulk$i" "PR for bulk$i"; done

# --- 10. GROKBOT_SKIP_WORKTREE_MISSING=1 stays a full opt-out: nothing checked, nothing sent. ---
new_wt optout commit
printf 'GROKBOT_SKIP_WORKTREE_MISSING=1\n' >> "$GROKBOT_HOOKS_DIR/test.env"
reset
remove_wt optout
sweep
expect_sends 0 'opt-out'
[ "$(gh_calls optout)" = 0 ] && [ "$(mapped optout)" = 1 ] || fail 'opt-out: checked or dropped'

echo 'PASS: missing worktrees (merged branch, merged/closed/open/foreign PR, settled/archived/deleted thread, gh failure and hang, kept directory, running turn, gh limit, opt-out)'
