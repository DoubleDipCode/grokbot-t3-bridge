# Plan: automatic T3 thread registry

Status: approved by Anton on 2026-11-05 and implemented in this branch.

## Decisions (Anton, 2026-11-05)

1. Codex thread ids use the read-only lookup in `~/.t3/userdata/statev2.sqlite` by worktree path (read-only, short timeout, fail soft: without it the callback goes out with an empty `thread_id`). Claude uses `T3CODE_THREAD_ID`.
2. No box-side mirror or `grokbot-threads` script. The routine receives the payload as prompt text, so `my_open_threads` in the payload is enough. Section 3's "Box-side piece" below is dropped.
3. `my_open_threads`: at most 8 short lines, only that bot's: open threads, `done` until settled or archived, and `worktree_missing`.
4. A merged PR does not close a row in this version.

Differences between this plan and the implementation: `enriched_at` is epoch seconds, there is a `removed` flag and a `final_since` column for pruning, and sweeps only update existing rows (so a pruned row is not recreated). Hook-driven runs refresh at most 3 + 3 rows; the launchd sweep refreshes 20 + 10. After a failed `t3` call the CLI is skipped for 5 minutes. See `docs/hooks.md#thread-registry` for the final behaviour.

## Goal

Bots should never call `t3_thread_list` or `t3_thread_search` to find their own
threads, and no bot should write registry entries by hand. Every callback names
its T3 thread. The Mac keeps a registry of bot-launched threads that updates
itself, and each callback carries a short summary of that bot's open threads.

## 1. How the hook learns the thread id

### Findings (read-only investigation on this Mac, T3 Code Beta, 2026-11-05)

| Source | Claude (T3) | Codex (T3) | Supported? |
| --- | --- | --- | --- |
| `T3CODE_THREAD_ID` env var | **yes** | **no** | Deliberate but undocumented |
| `t3 thread show <id> --json` (public CLI) | gives everything, once the id is known | same | Public CLI |
| `t3 thread list --project <path>` | no worktree or branch fields; a worktree path doesn't resolve to its project | same | Public, but no use here |
| T3 `statev2.sqlite`, looked up by `worktreePath` | works | works | **Internal** |
| Harness `session_id` → T3 binding table | no match: T3 stores its own provider-session ids | no match | Internal |
| Git config or worktree files | nothing T3-specific | nothing | – |

Evidence:

- **Env var.** This Claude thread's environment contains
  `T3CODE_THREAD_ID=mcp:launch:7d19…8c8c` and `T3CODE_CLI_PATH=/Users/anton/.t3/bin/t3`.
  `ps eww` shows the same values on the harness process (pid 39216).
  T3's bundled server (`app.asar`, `ClaudeAgentSdkQueryRunner.open`) sets
  `env: {...sdkOptions.env ?? hostEnvironment, [AGENT_THREAD_ENV]: input.threadId}`,
  where `AGENT_THREAD_ENV = "T3CODE_THREAD_ID"`. T3 also uses the variable itself,
  reading it back from `ps -E` and `/proc/<pid>/environ` to map processes to threads,
  so it's unlikely to vanish quietly. Hooks are child processes of the harness and
  inherit this environment. The Bash tool here inherits it too.
- **No env var for Codex.** The Codex app-server spawn
  (`makeCodexAppServerSpawnCommand`, `codexProcessEnvironment`) only adds
  `CODEX_HOME` and similar. One app-server is shared across threads
  (`shared: true`, session `provider-instance:codex_codex_proxy:shared`), so a
  per-thread env var isn't possible there.
- **Public CLI.** `t3 thread show "$T3CODE_THREAD_ID" --json --messages 0` returned
  `threadId, projectId, title, link, status, branch, worktreePath, archived,
  settled, settledAt, snoozed, pullRequests, linkedPullRequest, providerInstanceId,
  createdAt, updatedAt` in about 0.45 s. It needs no auth from a local shell. An
  unknown id exits with code 1 and prints "Thread X is no longer available.", which
  gives a clean "removed" signal.
- **Internal DB.** `~/.t3/userdata/statev2.sqlite`, table
  `orchestration_v2_projection_threads (thread_id, project_id, title, archived_at,
  deleted_at, payload_json)`. `payload_json` holds `worktreePath` and `branch`.
  1,116 live threads have a worktree path. A read-only lookup by worktree takes
  under 10 ms.

### Resolution order (in `notify.sh`, inside the existing background worker)

1. **Registry cache.** If the worktree's row already has a `thread_id`, use it.
   Nothing else runs on most turns.
2. **`T3CODE_THREAD_ID`** from the hook's environment (Claude Stop and Notification
   hooks). `source=env`.
3. **Codex, or env missing:** a read-only `sqlite3 "file:…statev2.sqlite?mode=ro"`
   query matching `json_extract(payload_json,'$.worktreePath')` to the worktree
   (both `pwd -P`-normalised), newest `updated_at`, `deleted_at IS NULL`. Wrapped in
   a 2 s timeout, with any error treated as "unknown". `source=t3db`. It can be
   turned off with `GROKBOT_T3_DB_LOOKUP=0`.
4. **Check and enrich** through the public CLI:
   `$GROKBOT_T3_CLI thread show <id> --json --messages 0`. This keeps the id only if
   `worktreePath` matches, and fills in title, projectId, branch, archived, settled
   and PR URL. If the CLI fails (server down), the hook keeps the id and enriches it
   later.
5. Nothing found: `thread_id` is empty, and today's branch/worktree matching still
   applies.

The CLI path is `GROKBOT_T3_CLI`, then `T3CODE_CLI_PATH`, then `~/.t3/bin/t3`.
launchd sweeps have no `T3CODE_*` env, so they rely on the cache and the default
path.

**Fallback I considered and didn't pick as the default:** a correlation token in
`.grokbot` line 2. The launching bot only gets the thread id after
`t3_thread_launch` returns, so it would have to record a token-to-thread mapping
itself, which is the manual registry work we want to avoid. Keep it only as an
escape hatch if T3 removes both the env var and the DB layout. In that case the
box-side script can map `branch` → `threadId` at launch time (see §3).

## 2. Registry on the Mac: `~/.grokbot-hooks/threads.sqlite`

It's written with `/usr/bin/sqlite3` (3.54, ships with macOS), so no new
dependency. Mode 600, WAL, `PRAGMA busy_timeout=3000`. Stop and sweep writes are
already serialised by the worker `flock`. Approval pings run without the lock, so
they only read, or do a single-statement upsert.

```sql
CREATE TABLE IF NOT EXISTS threads (
  worktree      TEXT PRIMARY KEY,         -- pwd -P of git toplevel, same key as markers.tsv
  bot           TEXT NOT NULL,
  thread_id     TEXT,                     -- T3 id, NULL until resolved
  thread_source TEXT,                     -- env | t3db | token | NULL
  title         TEXT,
  project_id    TEXT,
  branch        TEXT,
  harness       TEXT,                     -- claude | codex | sweep (last writer)
  session_id    TEXT,
  status_word   TEXT,                     -- first word of .grokbot-status (or stalled/stale/worktree_missing)
  status_note   TEXT,                     -- rest of status, 300 chars max
  last_message  TEXT,                     -- 300 chars max
  pr_url        TEXT,
  t3_status     TEXT,                     -- idle|running|... from `t3 thread show`
  archived      INTEGER NOT NULL DEFAULT 0,
  settled       INTEGER NOT NULL DEFAULT 0,
  state         TEXT NOT NULL DEFAULT 'open'
                CHECK (state IN ('open','done','worktree_missing','archived','settled','removed')),
  first_seen    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,            -- last hook write
  enriched_at   TEXT                      -- last successful `t3 thread show`
);
CREATE INDEX IF NOT EXISTS threads_bot_state ON threads(bot, state, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS threads_id ON threads(thread_id) WHERE thread_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);  -- schema_version, migrated_markers
```

The row is written on every hook run, including skips (dedupe or waiting), so the
registry reflects the latest status even when nothing was sent. The current hook
returns early on skip paths, so this upsert has to come before the skip checks.

State rules, highest priority first:

- `removed`: `t3 thread show` says the thread is no longer available.
- `archived` / `settled`: from `t3 thread show`.
- `worktree_missing`: set wherever `notify.sh` builds that status today.
- `done`: status word `done`.
- `open`: everything else.

**Migrating `markers.tsv`.** On first run (`meta.migrated_markers` unset), the hook
imports each `worktree<TAB>bot` line as `state=open` and `thread_id=NULL`, or as
`worktree_missing` when the directory is gone. The t3db lookup then resolves ids
lazily, at most 20 per sweep. `markers.tsv` stays the sweep's source of truth in
this change, so sweep and dedupe behaviour and the 500-entry cap don't change.
Dropping it can be a later, separate change.

**Refresh and cleanup**, at the end of each sweep (every 15 min under launchd):

- Re-enrich up to 10 non-final rows (`open`, `done`, `worktree_missing`) with
  `enriched_at` older than 30 min, oldest first. That's about 5 s of CLI calls per
  sweep at most, all in the background.
- Delete rows that have been `removed`, `archived` or `settled` for more than 30
  days.

**Debug CLI**, Mac-only: `~/.grokbot-hooks/threads.sh ls [bot] [--all]` prints the
same compact lines as the payload.

## 3. Getting it to the bots

### Payload (option a, recommended)

All changes are additive. Existing keys and their values don't change, so current
routines keep working.

```json
{
  "event": "t3_turn_ended", "bot": "codexbot", "...": "existing fields unchanged",
  "thread_id": "mcp:launch:7d19…",
  "thread_title": "Plan: automatic T3 thread registry for bots",
  "project_id": "mcp:5e6a137d-…",
  "thread_source": "env",
  "my_open_threads": [
    "mcp:launch:7d19…|needs_input|t3/thread-registry|Plan: automatic T3 thread regi…",
    "9df270c0-…|done|fix/login|Fix login redirect (PR #42)"
  ],
  "my_open_threads_more": 3
}
```

- `my_open_threads` lists this bot's rows in state `open`, `done` or
  `worktree_missing`, newest first. Each line is `id|word|branch|title`, with the
  title cut to 40 chars. There are at most 8 lines (`GROKBOT_SUMMARY_MAX`), so
  roughly 1 KB at most. `done` rows stay listed until T3 settles or archives them,
  so the bot can see unmerged work.
- Empty strings or an empty array when unknown. `GROKBOT_SUMMARY_MAX=0` turns the
  summary off.
- `last_message` stays at 1,500 bytes. The summary is the only real growth.

Changes to the routine prompt (`templates/routine-prompt.md`), and to each bot's
routine:

- Step 1 becomes "use `thread_id`. If it's empty, fall back to branch/worktree
  matching."
- "Use `my_open_threads` instead of listing threads."

### Box-side piece (option b, optional)

The payload already gives the bot what it needs, so the box script is only for
keeping state between callbacks. It's one line in the routine:

```bash
printf '%s' "$PAYLOAD" | ~/bin/grokbot-threads put   # writes ~/.grokbot-threads/<bot>.json keyed by thread_id
~/bin/grokbot-threads ls <bot>                         # same compact lines, any time, no T3 call
```

It's about 30 lines of bash and jq, needs no daemon, and keeps the latest entry
per thread with a 200-row cap. It also offers
`grokbot-threads launched <threadId> <branch> <title>`, which records a mapping
when a launch happens. That's useful only for the escape hatch in §1.

Rejected options:

- Exposing the Mac's registry over HTTP. That's a new daemon and a new attack
  surface.
- A periodic digest push. It wakes bots for nothing.

## 4. Compatibility

- The payload is a superset: same `event` and same existing fields.
  `tests/notify-http-test.py` asserts the old keys still exist.
- Codex and every Claude config dir use the same `notify.sh`, so `install.sh`'s
  hook registration doesn't change. `install.sh` only copies new files
  (`threads.sh`). `uninstall.sh` leaves `threads.sqlite` alone, like
  `markers.tsv`.
- Dedupe, waiting/stale, stall and approval logic stay as they are. Registry
  writes and CLI calls run in the existing background worker and never block the
  harness. Any registry error is logged as `registry-error` and ignored.
- No new daemons. Refresh piggybacks on the existing launchd sweep.

## 5. Implementation and rollout steps

1. **`hooks/registry-lib.sh`**, sourced by `notify.sh`. It provides
   `registry_init` (schema and migration), `registry_resolve <worktree>`,
   `registry_upsert`, `registry_summary <bot>` and `registry_refresh`. All SQL uses
   bound parameters through `sqlite3 -cmd ".parameter set"`, or the values go
   through a single quote-escaping helper. Worktree paths and titles are untrusted.
2. `notify.sh`:
   - Capture `T3CODE_THREAD_ID` before backgrounding the worker, and pass it as a
     worker argument.
   - Upsert on every `process` and `approval` call.
   - Add the new fields in `post()`.
   - Call `registry_refresh` after `sweep`.
3. Tests, without Docker:
   - A stub `t3` script via `GROKBOT_T3_CLI`, and a fixture `statev2.sqlite`
     built in a temp dir via `GROKBOT_T3_DB`.
   - Cover: env-id resolution, Codex DB resolution, CLI mismatch rejection,
     removed thread, `markers.tsv` migration, summary cap, old keys present, and
     dedupe unchanged.
4. Docs: `docs/hooks.md` payload schema, the routine prompt, the README
   "What's in here" table, and `ONE-SHOT-PROMPT.md`.
5. PR, then an independent review (Codex Proxy, GPT-6.1 Sol) before merging.
6. **Shadow install** on the Mac with `GROKBOT_SUMMARY_MAX=0`. For a day, read
   `notify.log` `thread=… source=…` lines and confirm both Claude and Codex threads
   resolve.
7. Turn on the summary. Update one bot's routine, then the other 11.
8. Optional: deploy `grokbot-threads` on the box.

## 6. Risks

- **The internal DB layout can change with any T3 update.** It's used only for
  Codex, or when the env var is missing. It's read-only, every result is checked
  through the public CLI, and failure just means an empty `thread_id`. The
  shadow-mode log and tests catch it.
- **`T3CODE_THREAD_ID` is undocumented.** It could be renamed. Same mitigation:
  the t3db fallback, then the old matching.
- **Each `t3 thread show` call starts T3's Electron-as-node runtime** (about
  0.5 s, about 60 MB). That's once per new thread plus 10 per sweep at most.
- **SQLite locking** between approval pings and the worker. Mitigated with
  `busy_timeout` and single statements.
- **Stale `open` rows** if T3 never settles or archives a thread. Mitigated by
  refresh plus the 30-day prune. Rows can still sit at `done` until settled.
- **Titles can contain injected text.** Payload fields stay untrusted data, as the
  routine prompt already says.

## 7. Open questions for Anton

1. Is the read-only lookup in T3's `statev2.sqlite` acceptable for Codex threads?
   The alternative is no thread id for Codex until T3 sets the env var there. That
   one may be worth asking T3 for.
2. How does a Grok Bot routine hand the payload to a shell command: stdin, an env
   var, or a temp file? This decides whether the box script is really one line.
3. Which threads should `my_open_threads` include? The proposal is open, done
   (until settled or archived) and worktree_missing, capped at 8.
4. Should rows be marked `done`/closed when a PR merges? That needs a `gh` call
   from the Mac and isn't in this plan.
