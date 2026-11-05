#!/bin/bash
# shellcheck disable=SC2034,SC2153 # globals set here are read by notify.sh; ROOT, STATUS etc. are set there
# Thread registry for notify.sh. Meant to be sourced, not run.
#
# Keeps ~/.grokbot-hooks/threads.sqlite: one row per marked worktree, with the T3 thread behind it
# (id, title, project), the latest status and a state (open/done/worktree_missing/archived/settled/
# removed). notify.sh updates it on every hook run and puts thread_id plus a short summary of the
# bot's open threads in the webhook payload, so bots never have to list or search T3 threads.
#
# Everything here is best effort. A failure is logged as "registry-error" and the callback goes out
# without the thread fields. Nothing in this file may block, fail or change a callback.
#
# How the thread id is found, in order (see docs/plans/thread-registry.md):
#   1. T3CODE_THREAD_ID in the hook's environment (T3 sets it for Claude Code sessions).
#   2. A read-only lookup in T3's state database by worktree path (Codex sessions have no env var).
#   3. The id already stored for the worktree.
# A candidate is then checked against T3's own CLI (`t3 thread show <id> --json`), which must report
# the same worktree. If the CLI is unavailable the candidate is used unchecked.
#
# Config (environment or ~/.grokbot-hooks/config):
#   GROKBOT_REGISTRY=0         turn the registry off (payload thread fields are then empty)
#   GROKBOT_SUMMARY_MAX=8      lines in my_open_threads (0 = leave the summary out)
#   GROKBOT_T3_CLI=<path>      the t3 command (default: $T3CODE_CLI_PATH, then ~/.t3/bin/t3)
#   GROKBOT_T3_DB=<path>       T3 state database (default: ${T3CODE_HOME:-~/.t3}/userdata/statev2.sqlite)
#   GROKBOT_T3_DB_LOOKUP=0     never read T3's database

REG_DB="${GROKBOT_REGISTRY_DB:-$DIR/threads.sqlite}"
REG_US=$'\x1f'                       # field separator for sqlite output; cleaned values never contain it
REG_ENRICH_FRESH=600                 # seconds a successful `t3 thread show` counts as current
REG_REFRESH_AGE=1800                 # sweeps re-check rows older than this
REG_PRUNE_DAYS=30                    # final rows (archived/settled/removed) are deleted after this
REG_BREAKER_SECONDS=300              # after a CLI failure, skip the CLI for this long
REG_SQLITE="$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)"

# The state of a row from its flags and status word. Used in a separate UPDATE after the columns
# change, because an UPDATE's expressions read the old values.
REG_STATE_SQL="CASE WHEN removed=1 THEN 'removed' WHEN archived=1 THEN 'archived' WHEN settled=1 THEN 'settled' WHEN status_word='worktree_missing' THEN 'worktree_missing' WHEN status_word='done' THEN 'done' ELSE 'open' END"

reg_on() {
  [ "${GROKBOT_REGISTRY:-1}" != 0 ] && [ -x "$REG_SQLITE" ]
}

# reg_q <string>: sets REG_Q to the string as a quoted SQL literal.
reg_q() {
  local s="$1"
  s=${s//\'/\'\'}
  REG_Q="'$s'"
}

# reg_clean <string> <max bytes> [field]: sets REG_C to one line with no control characters. With a
# third argument "field" the | character is replaced too, because summary lines are |-separated.
reg_clean() {
  REG_C="$(printf '%s' "$1" | head -c "$2" | tr '\000-\037' ' ')"
  [ "${3:-}" != field ] || REG_C="${REG_C//|//}"
}

# reg_run: runs SQL from stdin. Prints sqlite's output. Logs a failure and returns non-zero.
reg_run() {
  local out rc
  out="$("$REG_SQLITE" -batch -cmd '.timeout 3000' -separator "$REG_US" -nullvalue '' "$REG_DB" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || echo "$(date '+%Y-%m-%dT%H:%M:%S%z') registry-error sqlite rc=$rc" >> "$LOG"
  printf '%s' "$out"
  return "$rc"
}

# reg_timeout <seconds> <command...>: portable timeout (macOS has none). Exit 142 on timeout.
reg_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

reg_realpath() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

registry_init() {
  local v path bot word branch sql=""
  [ -z "${REG_READY:-}" ] || return 0
  reg_on || return 1
  reg_run >/dev/null <<'SQL' || return 1
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS threads (
  worktree      TEXT PRIMARY KEY,
  bot           TEXT NOT NULL,
  thread_id     TEXT,
  thread_source TEXT,
  title         TEXT,
  project_id    TEXT,
  branch        TEXT,
  harness       TEXT,
  session_id    TEXT,
  status_word   TEXT,
  status_note   TEXT,
  last_message  TEXT,
  pr_url        TEXT,
  t3_status     TEXT,
  archived      INTEGER NOT NULL DEFAULT 0,
  settled       INTEGER NOT NULL DEFAULT 0,
  removed       INTEGER NOT NULL DEFAULT 0,
  state         TEXT NOT NULL DEFAULT 'open'
                CHECK (state IN ('open','done','worktree_missing','archived','settled','removed')),
  final_since   INTEGER,
  first_seen    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  enriched_at   INTEGER,
  resolve_tried INTEGER,
  started_at    INTEGER
);
CREATE INDEX IF NOT EXISTS threads_bot_state ON threads(bot, state, updated_at);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
INSERT OR IGNORE INTO meta VALUES ('schema_version', '1');
SQL
  # Databases made before turn-start hooks lack started_at (epoch of the running turn, NULL when none).
  # Tolerate losing a race with another process that adds it first.
  v="$(reg_run <<< "SELECT count(*) FROM pragma_table_info('threads') WHERE name='started_at';")"
  [ "$v" != 0 ] || reg_run >/dev/null <<< "ALTER TABLE threads ADD COLUMN started_at INTEGER;" || true
  # One-time import of markers.tsv (worktree<TAB>bot). The map stays the sweep's source of truth.
  v="$(reg_run <<< "SELECT v FROM meta WHERE k='migrated_markers';")"
  if [ -z "$v" ] && [ -f "$MAP" ]; then
    while IFS=$'\t' read -r path bot; do
      [ -n "$path" ] && [ -n "$bot" ] || continue
      bot="$(printf '%s' "$bot" | tr -cd 'a-z0-9_-')"
      [ -n "$bot" ] || continue
      if [ -d "$path" ]; then
        word="$(head -n1 "$path/.grokbot-status" 2>/dev/null | awk '{print $1}' | head -c 40)"
        [ -n "$word" ] || word=turn_ended_no_status
        branch="$(git -C "$path" branch --show-current 2>/dev/null)"
      else
        word=worktree_missing
        branch=
      fi
      reg_clean "$word" 40 field; word="$REG_C"
      reg_clean "$branch" 200 field; branch="$REG_C"
      reg_q "$path"; sql="$sql INSERT OR IGNORE INTO threads(worktree,bot,branch,status_word,status_note,first_seen,updated_at) VALUES($REG_Q"
      reg_q "$bot"; sql="$sql,$REG_Q"
      reg_q "$branch"; sql="$sql,$REG_Q"
      reg_q "$word"; sql="$sql,$REG_Q,'','${TS:-}','${TS:-}');"
    done < "$MAP"
    reg_run >/dev/null <<SQL || return 1
BEGIN;
$sql
UPDATE threads SET state=$REG_STATE_SQL WHERE state != $REG_STATE_SQL;
INSERT OR REPLACE INTO meta VALUES ('migrated_markers', '${TS:-done}');
COMMIT;
SQL
  fi
  REG_READY=1
}

# registry_record <start|turn|sweep|approval>
# Writes the status of ROOT. Reads the globals ROOT BOT HARNESS SESSION LAST STATUS WORD TS.
#   start     a turn began (UserPromptSubmit hook, or a sweep adopting a pending start): status
#             "running", started_at = START_EPOCH (default now). Creates the row if needed.
#   turn      a harness turn ended: full row, including harness, session and last message. Clears
#             started_at, unless a newer turn has already started.
#   approval  a prompt is waiting: the status fields only; creates the row if needed.
#   sweep     the sweep looked at a worktree: updates an existing row only (a pruned row must stay
#             pruned) and moves updated_at only when the status changed.
# While a turn is running (started_at set), sweep and approval keep the row's status as it is until
# the status file is rewritten, because the file still holds the previous turn's status.
registry_record() {
  local mode="$1" branch note set upd ins started mtime keep
  REG_SNAP_ROOT=
  registry_init || return 0
  branch="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
  note="${STATUS#"$WORD"}"
  note="${note#"${note%%[![:space:]]*}"}"
  reg_clean "$note" 300; note="$REG_C"
  reg_clean "$WORD" 40 field; WORD_C="$REG_C"
  reg_clean "$branch" 200 field; branch="$REG_C"
  local q_root q_bot q_branch q_word q_note q_harness q_session q_last q_ts
  reg_q "$ROOT"; q_root="$REG_Q"
  reg_q "$BOT"; q_bot="$REG_Q"
  reg_q "$branch"; q_branch="$REG_Q"
  reg_q "$WORD_C"; q_word="$REG_Q"
  reg_q "$note"; q_note="$REG_Q"
  reg_q "${HARNESS%-start}"; q_harness="$REG_Q"
  reg_q "$SESSION"; q_session="$REG_Q"
  reg_clean "$LAST" 300; reg_q "$REG_C"; q_last="$REG_Q"
  reg_q "$TS"; q_ts="$REG_Q"
  started=NULL
  case "$mode" in
    start) started="${START_EPOCH:-$(date +%s)}"; case "$started" in *[!0-9]*|'') started="$(date +%s)" ;; esac ;;
    turn) ;;
    *) mtime="$(perl -e 'print((stat($ARGV[0]))[9] // 0)' "$ROOT/.grokbot-status" 2>/dev/null)"
       case "$mtime" in *[!0-9]*|'') mtime=0 ;; esac ;;
  esac
  set="bot=$q_bot, branch=COALESCE(NULLIF($q_branch,''),branch)"
  case "$mode" in
    start)
      set="$set, status_word=$q_word, status_note=$q_note, harness=$q_harness, session_id=COALESCE(NULLIF($q_session,''),session_id), started_at=$started, updated_at=$q_ts" ;;
    turn)
      set="$set, status_word=$q_word, status_note=$q_note, harness=$q_harness, session_id=COALESCE(NULLIF($q_session,''),session_id), last_message=$q_last, updated_at=$q_ts"
      set="$set, started_at=CASE WHEN started_at > ${START_BEFORE:-$(date +%s)} THEN started_at ELSE NULL END" ;;
    *)
      keep="(started_at IS NOT NULL AND $mtime < started_at)"
      set="$set, status_word=CASE WHEN $keep THEN status_word ELSE $q_word END, status_note=CASE WHEN $keep THEN status_note ELSE $q_note END"
      set="$set, updated_at=CASE WHEN $keep THEN updated_at WHEN status_word IS NOT $q_word OR status_note IS NOT $q_note THEN $q_ts ELSE updated_at END" ;;
  esac
  upd="UPDATE threads SET $set WHERE worktree=$q_root;"
  ins="INSERT OR IGNORE INTO threads(worktree,bot,branch,harness,session_id,status_word,status_note,last_message,first_seen,updated_at,started_at) VALUES($q_root,$q_bot,$q_branch,$q_harness,$q_session,$q_word,$q_note,$q_last,$q_ts,$q_ts,$started);"
  [ "$mode" != sweep ] || ins=
  reg_run >/dev/null <<SQL || true
BEGIN;
$ins
$upd
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$q_root;
UPDATE threads SET final_since=CASE WHEN state IN ('removed','archived','settled') THEN COALESCE(final_since,$(date +%s)) ELSE NULL END WHERE worktree=$q_root;
COMMIT;
SQL
}

# registry_mark_stalled <note>: the sweep reported a dead turn for ROOT. Shows "stalled" instead of
# the previous turn's status until the next turn starts or ends.
registry_mark_stalled() {
  local q_root q_note
  registry_init || return 0
  reg_clean "$1" 300; reg_q "$REG_C"; q_note="$REG_Q"
  reg_q "$ROOT"; q_root="$REG_Q"
  reg_run >/dev/null <<SQL || true
BEGIN;
UPDATE threads SET status_word='stalled', status_note=$q_note, updated_at='$TS' WHERE worktree=$q_root;
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$q_root;
COMMIT;
SQL
}

# reg_db_lookup <root>: sets DB_ID DB_TITLE DB_PROJECT from T3's database, read-only, by worktree path.
# This reads T3's internal storage, which is not a public interface: any failure means "unknown".
reg_db_lookup() {
  local root="$1" real db out
  DB_ID=; DB_TITLE=; DB_PROJECT=
  [ "${GROKBOT_T3_DB_LOOKUP:-1}" != 0 ] || return 1
  db="${GROKBOT_T3_DB:-${T3CODE_HOME:-$HOME/.t3}/userdata/statev2.sqlite}"
  [ -f "$db" ] || return 1
  real="$(reg_realpath "$root")"
  reg_q "$root"; local q1="$REG_Q"
  reg_q "$real"; local q2="$REG_Q"
  out="$(reg_timeout 3 "$REG_SQLITE" -readonly -batch -cmd '.timeout 1500' -separator "$REG_US" -nullvalue '' "$db" \
    "SELECT thread_id, COALESCE(project_id,''), replace(replace(COALESCE(title,''),char(10),' '),char(13),' ')
       FROM orchestration_v2_projection_threads
      WHERE deleted_at IS NULL AND json_extract(payload_json,'\$.worktreePath') IN ($q1,$q2)
      ORDER BY (archived_at IS NULL) DESC, updated_at DESC LIMIT 1;" 2>/dev/null | head -n1)" || return 1
  [ -n "$out" ] || return 1
  IFS="$REG_US" read -r DB_ID DB_PROJECT DB_TITLE <<< "$out"
  [ -n "$DB_ID" ]
}

# reg_verify <root> <thread id>: asks T3's CLI about the thread. Sets V_ID V_PROJECT V_TITLE V_ARCHIVED
# V_SETTLED V_STATUS V_PR. Returns 0 (thread exists and lives in this worktree), 1 (other worktree),
# 2 (CLI unavailable or failed) or 3 (T3 says the thread no longer exists).
reg_verify() {
  local root="$1" id="$2" cli out errf rc line wp breaker
  cli="${GROKBOT_T3_CLI:-${T3CODE_CLI_PATH:-$HOME/.t3/bin/t3}}"
  [ -x "$cli" ] || return 2
  breaker="$STATE/t3cli.fail"
  if [ -f "$breaker" ] && [ -z "$(find "$breaker" -mmin "+$((REG_BREAKER_SECONDS / 60))" -print 2>/dev/null)" ]; then
    return 2   # failed recently: do not hold the sweep lock on a dead server again
  fi
  mkdir -p "$STATE" 2>/dev/null
  errf="$(mktemp "$STATE/t3err.XXXXXX" 2>/dev/null)" || return 2
  out="$(reg_timeout 8 "$cli" thread show "$id" --json --messages 0 2>"$errf" </dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -q 'no longer available' "$errf" 2>/dev/null; then rm -f "$errf"; return 3; fi
    rm -f "$errf"
    touch "$breaker" 2>/dev/null
    echo "$TS registry-error t3-cli rc=$rc" >> "$LOG"
    return 2
  fi
  rm -f "$errf" "$breaker"
  line="$(printf '%s' "$out" | "$JQ" -r '.thread | [
      .threadId, (.projectId // ""), (.title // ""), (.worktreePath // ""),
      ((.archived // false) | if . then 1 else 0 end), ((.settled // false) | if . then 1 else 0 end),
      (.status // ""), ((.linkedPullRequest.url? // (.pullRequests // [] | last | .url?)) // "")
    ] | map(tostring | gsub("[\\x00-\\x1f]"; " ")) | join("\u001f")' 2>/dev/null)"
  [ -n "$line" ] || return 2
  IFS="$REG_US" read -r V_ID V_PROJECT V_TITLE wp V_ARCHIVED V_SETTLED V_STATUS V_PR <<< "$line"
  [ "$V_ID" = "$id" ] || return 2
  [ -n "$wp" ] && [ "$(reg_realpath "$wp")" = "$(reg_realpath "$root")" ] || return 1
  return 0
}

# reg_store <root> <id> <source> <verified 0|1> [title project]: writes the thread fields of a row.
# Verified data comes from the CLI (V_*); unverified data keeps the title and project given.
reg_store() {
  REG_SNAP_ROOT="$1"; THREAD_ID="$2"; THREAD_SOURCE="$3"
  local root="$1" id="$2" src="$3" verified="$4" title project pr st arch settl enriched
  if [ "$verified" = 1 ]; then
    title="$V_TITLE"; project="$V_PROJECT"; pr="$V_PR"; st="$V_STATUS"; arch="$V_ARCHIVED"; settl="$V_SETTLED"; enriched="$(date +%s)"
  else
    title="${5:-}"; project="${6:-}"; pr=; st=; arch=0; settl=0; enriched=NULL
  fi
  reg_clean "$title" 200 field; title="$REG_C"
  reg_clean "$project" 200; project="$REG_C"
  THREAD_TITLE="$title"; PROJECT_ID="$project"
  local q_root q_id q_src q_title q_proj q_pr q_st
  reg_q "$root"; q_root="$REG_Q"; reg_q "$id"; q_id="$REG_Q"; reg_q "$src"; q_src="$REG_Q"
  reg_q "$title"; q_title="$REG_Q"; reg_q "$project"; q_proj="$REG_Q"
  reg_q "$pr"; q_pr="$REG_Q"; reg_q "$st"; q_st="$REG_Q"
  reg_run >/dev/null <<SQL || true
BEGIN;
UPDATE threads SET thread_id=$q_id, thread_source=$q_src, title=$q_title, project_id=$q_proj, pr_url=$q_pr,
  t3_status=$q_st, archived=$arch, settled=$settl, removed=0, enriched_at=$enriched WHERE worktree=$q_root;
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$q_root;
UPDATE threads SET final_since=CASE WHEN state IN ('removed','archived','settled') THEN COALESCE(final_since,$(date +%s)) ELSE NULL END WHERE worktree=$q_root;
COMMIT;
SQL
}

# reg_mark_removed <root>: T3 says the thread behind this row is gone.
reg_mark_removed() {
  reg_q "$1"
  reg_run >/dev/null <<SQL || true
BEGIN;
UPDATE threads SET removed=1, enriched_at=$(date +%s) WHERE worktree=$REG_Q;
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$REG_Q;
UPDATE threads SET final_since=COALESCE(final_since,$(date +%s)) WHERE worktree=$REG_Q AND state='removed';
COMMIT;
SQL
}

# reg_clear_thread <root> <id>: T3 says <id> lives in another worktree, so this row must not name it.
# Conditional on the id, so a newer mapping written meanwhile is left alone.
reg_clear_thread() {
  reg_q "$1"; local qr="$REG_Q"
  reg_q "$2"
  reg_run >/dev/null <<SQL || true
UPDATE threads SET thread_id=NULL, thread_source=NULL, title=NULL, project_id=NULL, pr_url=NULL, t3_status=NULL,
  archived=0, settled=0, removed=0, enriched_at=NULL WHERE worktree=$qr AND thread_id=$REG_Q;
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$qr;
SQL
}

# registry_resolve <root> [env thread id]
# Finds the T3 thread behind ROOT and stores it. Only the hook of the current session may pass an
# env id: a sweep looking at other worktrees must not.
registry_resolve() {
  REG_SNAP_ROOT=
  reg__resolve "$@"
  # Paths that kept the stored thread (fresh, or nothing better found) did not call reg_store.
  [ -n "$REG_SNAP_ROOT" ] || { registry_load_thread "$1"; REG_SNAP_ROOT="$1"; }
  return 0
}
reg__resolve() {
  local root="$1" env_id="${2:-}" now row cached cenr fresh=0 rc src
  registry_init || return 0
  [ -d "$root" ] || return 0
  now="$(date +%s)"
  reg_q "$root"
  row="$(reg_run <<< "SELECT COALESCE(thread_id,''), COALESCE(enriched_at,'') FROM threads WHERE worktree=$REG_Q;")"
  IFS="$REG_US" read -r cached cenr <<< "$row"
  [ -z "$cenr" ] || [ "$((now - cenr))" -ge "$REG_ENRICH_FRESH" ] || fresh=1
  # 1. T3CODE_THREAD_ID from the harness environment.
  if [ -n "$env_id" ]; then
    if [ "$env_id" = "$cached" ] && [ "$fresh" = 1 ]; then return 0; fi
    reg_verify "$root" "$env_id"; rc=$?
    case "$rc" in
      0) reg_store "$root" "$env_id" env 1; return 0 ;;
      2) ;;                 # cannot check: weigh it against the database lookup below
      *) env_id= ;;         # other worktree, or gone: not this worktree's thread
    esac
  fi
  # 2. T3's database, by worktree path.
  if reg_db_lookup "$root"; then
    if [ "$DB_ID" = "$cached" ] && [ "$fresh" = 1 ]; then return 0; fi
    reg_verify "$root" "$DB_ID"; rc=$?
    case "$rc" in
      0) reg_store "$root" "$DB_ID" t3db 1; return 0 ;;
      2) reg_store "$root" "$DB_ID" t3db 0 "$DB_TITLE" "$DB_PROJECT"; return 0 ;;
    esac
  fi
  # An unchecked env id is better than nothing.
  if [ -n "$env_id" ]; then reg_store "$root" "$env_id" env 0; return 0; fi
  # 3. Keep what is stored, and re-check it when it has gone stale.
  if [ -n "$cached" ] && [ "$fresh" = 0 ]; then
    reg_verify "$root" "$cached"; rc=$?
    case "$rc" in
      0) reg_q "$root"; src="$(reg_run <<< "SELECT COALESCE(thread_source,'') FROM threads WHERE worktree=$REG_Q;")"
         reg_store "$root" "$cached" "$src" 1 ;;
      3) reg_mark_removed "$root" ;;
      1) reg_clear_thread "$root" "$cached"; THREAD_ID=; THREAD_TITLE=; PROJECT_ID=; THREAD_SOURCE=; REG_SNAP_ROOT="$root" ;;
    esac
  fi
  return 0
}

# registry_load_thread <root>: sets THREAD_ID THREAD_TITLE PROJECT_ID THREAD_SOURCE (empty if unknown).
registry_load_thread() {
  local row
  # The callback's own resolution wins over the shared row: an approval ping for the same worktree
  # running at the same time (it takes no lock) could have rewritten the row in between.
  [ "${REG_SNAP_ROOT:-}" != "$1" ] || return 0
  THREAD_ID=; THREAD_TITLE=; PROJECT_ID=; THREAD_SOURCE=
  reg_on && [ -f "$REG_DB" ] || return 0
  reg_q "$1"
  row="$(reg_run <<< "SELECT COALESCE(thread_id,''), COALESCE(title,''), COALESCE(project_id,''), COALESCE(thread_source,'') FROM threads WHERE worktree=$REG_Q;")" || return 0
  IFS="$REG_US" read -r THREAD_ID THREAD_TITLE PROJECT_ID THREAD_SOURCE <<< "$row"
}

# registry_summary <bot>: sets SUMMARY_JSON (a JSON array of at most GROKBOT_SUMMARY_MAX strings
# "id|status word|branch|title", newest first) and SUMMARY_MORE (how many more open threads there
# are). Only this bot's rows in state open, done or worktree_missing.
registry_summary() {
  local max="${GROKBOT_SUMMARY_MAX:-8}" out n lines sql
  SUMMARY_JSON='[]'; SUMMARY_MORE=0
  case "$max" in *[!0-9]*|'') max=8 ;; esac
  [ "${#max}" -le 2 ] || max=20
  max=$((10#$max))   # "08" is decimal, not an octal error
  [ "$max" -le 20 ] || max=20
  [ "$max" -gt 0 ] || return 0
  reg_on && [ -f "$REG_DB" ] || return 0
  reg_q "$1"
  sql="SELECT count(*) FROM threads WHERE bot=$REG_Q AND state IN ('open','done','worktree_missing');
SELECT COALESCE(NULLIF(thread_id,''),'-') || '|' || COALESCE(status_word,'') || '|' || COALESCE(branch,'') || '|' || substr(COALESCE(NULLIF(title,''),'?'),1,40)
  FROM threads WHERE bot=$REG_Q AND state IN ('open','done','worktree_missing')
  ORDER BY updated_at DESC LIMIT $max;"
  out="$(reg_run <<< "$sql")" || return 0
  n="$(printf '%s\n' "$out" | head -n1)"
  case "$n" in *[!0-9]*|'') return 0 ;; esac
  lines="$(printf '%s\n' "$out" | tail -n +2)"
  SUMMARY_JSON="$(printf '%s' "$lines" | "$JQ" -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" || SUMMARY_JSON='[]'
  [ -n "$SUMMARY_JSON" ] || SUMMARY_JSON='[]'
  SUMMARY_MORE=$((n > max ? n - max : 0))
}

# registry_refresh [full]: end of a worker run. Resolves rows that have no thread yet, re-checks the
# oldest stale rows (3 + 3 per call, 20 + 10 with "full" from the launchd sweep) and deletes final rows older than REG_PRUNE_DAYS.
registry_refresh() {
  local now path id rows sql n_new=3 n_old=3 budget=12 deadline
  [ "${1:-}" != full ] || { n_new=20; n_old=10; budget=60; }
  registry_init || return 0
  now="$(date +%s)"
  deadline=$((now + budget))   # the sweep lock is held meanwhile: stop early rather than delay callbacks
  rows="$(reg_run <<< "SELECT worktree FROM threads WHERE thread_id IS NULL AND state IN ('open','done') ORDER BY COALESCE(resolve_tried,0), updated_at DESC LIMIT $n_new;")" || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || break
    # Remember the attempt so rows that never resolve (not T3 worktrees) do not hog every batch.
    reg_q "$path"; reg_run >/dev/null <<< "UPDATE threads SET resolve_tried=$(date +%s) WHERE worktree=$REG_Q;" || true
    registry_resolve "$path"
  done <<< "$rows"
  sql="SELECT worktree, thread_id FROM threads
 WHERE thread_id IS NOT NULL AND state IN ('open','done','worktree_missing')
   AND (enriched_at IS NULL OR enriched_at < $((now - REG_REFRESH_AGE)))
 ORDER BY COALESCE(enriched_at,0) LIMIT $n_old;"
  rows="$(reg_run <<< "$sql")" || return 0
  while IFS="$REG_US" read -r path id; do
    [ -n "$path" ] && [ -n "$id" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || break
    if [ ! -d "$path" ]; then
      # Gone from disk: T3 may still know the thread (settled/archived), so ask about it by id only.
      reg_verify_by_id "$path" "$id"
    else
      registry_resolve "$path"
    fi
  done <<< "$rows"
  reg_run >/dev/null <<SQL || true
DELETE FROM threads WHERE final_since IS NOT NULL AND final_since < $((now - REG_PRUNE_DAYS * 86400));
SQL
}

# reg_verify_by_id <root> <id>: refresh a row whose worktree directory no longer exists. The path
# cannot be compared, so only the archived/settled/removed flags are taken from T3.
reg_verify_by_id() {
  local root="$1" id="$2" cli out rc
  cli="${GROKBOT_T3_CLI:-${T3CODE_CLI_PATH:-$HOME/.t3/bin/t3}}"
  [ -x "$cli" ] || return 0
  [ ! -f "$STATE/t3cli.fail" ] || [ -n "$(find "$STATE/t3cli.fail" -mmin "+$((REG_BREAKER_SECONDS / 60))" -print 2>/dev/null)" ] || return 0
  out="$(reg_timeout 8 "$cli" thread show "$id" --json --messages 0 2>&1 </dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *'no longer available'*) reg_mark_removed "$root" ;;
      *) touch "$STATE/t3cli.fail" 2>/dev/null; echo "$TS registry-error t3-cli rc=$rc" >> "$LOG" ;;
    esac
    return 0
  fi
  local flags
  flags="$(printf '%s' "$out" | "$JQ" -r '.thread | [((.archived // false) | if . then 1 else 0 end), ((.settled // false) | if . then 1 else 0 end), (.status // "")] | join("\u001f")' 2>/dev/null)"
  [ -n "$flags" ] || return 0
  local a s st
  IFS="$REG_US" read -r a s st <<< "$flags"
  reg_q "$root"; local qr="$REG_Q"
  reg_clean "$st" 40; reg_q "$REG_C"
  reg_run >/dev/null <<SQL || true
BEGIN;
UPDATE threads SET archived=$a, settled=$s, t3_status=$REG_Q, removed=0, enriched_at=$(date +%s) WHERE worktree=$qr;
UPDATE threads SET state=$REG_STATE_SQL WHERE worktree=$qr;
UPDATE threads SET final_since=CASE WHEN state IN ('removed','archived','settled') THEN COALESCE(final_since,$(date +%s)) ELSE NULL END WHERE worktree=$qr;
COMMIT;
SQL
}
