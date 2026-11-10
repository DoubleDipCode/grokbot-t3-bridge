# Turn-end hooks

## Why a hook and not "curl when you're done"

You could put "when you finish, curl this URL" in the brief instead. That has three problems:

- The agent forgets, or stops early on an error, and nothing is sent.
- The webhook URL and key would have to be in the brief, which means in the thread, the transcript and maybe the logs.
- Every brief has to repeat the instructions correctly.

A `Stop` hook is run by the harness at the end of every turn, whether the agent remembers or not. The secret stays in a file on the machine. The agent's only job is to write a one-line status to a file, and if it skips that, the payload says `turn_ended_no_status` and the bot reads the thread.

See [Claude Code](claude-code.md) or [Codex CLI](codex-cli.md) for standalone use.
Registration and stdin fields were checked on 2026-11-01 against the
[Claude hooks reference](https://code.claude.com/docs/en/hooks) and
[Codex hooks reference](https://developers.openai.com/codex/hooks).

## Codex

Codex reads hooks from `~/.codex/hooks.json`. `install.sh` adds this entry (with `$HOME` expanded to an absolute path):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.grokbot-hooks/notify.sh codex",
            "timeout": 15,
            "statusMessage": "Notifying Grok Bot"
          }
        ]
      }
    ]
  }
}
```

Two things to know:

1. **Codex only runs hooks you have trusted.** After installing, or after any change to the hook, run `codex`, type `/hooks`, and trust it.
2. **Running sessions keep the hook set they started with.** Threads that were already open will not pick up the new hook. Start a fresh thread to test.

`install.sh` also adds `PermissionRequest` with `notify.sh codex-permission` and `UserPromptSubmit` with `notify.sh codex-start`; trust both in `/hooks` too (for every Codex home you use, e.g. plain `codex` and `CODEX_HOME=~/.codex-t3/proxy codex`; `install.sh` only writes `~/.codex/hooks.json`). See [Approval-prompt pings](#approval-prompt-pings) and [Turn-start hook](#turn-start-hook).

Codex passes `last_assistant_message` on stdin, so the payload includes the agent's last message.

## Claude Code

Claude Code reads hooks from `~/.claude/settings.json`. `install.sh` adds:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.grokbot-hooks/notify.sh claude",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

`install.sh` also adds the `Notification` event (command `notify.sh claude-notify`) and the `UserPromptSubmit` event (command `notify.sh claude-start`, see [Turn-start hook](#turn-start-hook)) and writes all three entries to every Claude config dir it finds: `~/.claude`, `$CLAUDE_CONFIG_DIR` when set, and every other `~/.claude-*` directory that contains a `settings.json` (for example one per provider, each launched with its own `CLAUDE_CONFIG_DIR`). To name other dirs, or to replace the list, set `GROKBOT_EXTRA_CLAUDE_DIRS` or `GROKBOT_CLAUDE_DIRS` in the environment or in `~/.grokbot-hooks/config` (see the [README](../README.md#configuration)). Existing keys such as `env` are merged, never dropped or printed. See [Approval-prompt pings](#approval-prompt-pings).

Review the command in `/hooks`. Claude also provides `last_assistant_message`;
older versions may omit it. This setup does not register StopFailure or interrupt hooks.

## Turn-start hook

Stop never fires when a harness dies mid-turn, so a worktree whose thread died on its first turn was in neither `markers.tsv` nor the registry, and one whose follow-up turn died looked `done` (never swept) or `waiting` (only the two-hour reminder). The turn-start hook fixes both.

| Harness | Event | Command |
| --- | --- | --- |
| Claude Code | `UserPromptSubmit` | `notify.sh claude-start` |
| Codex | `UserPromptSubmit` | `notify.sh codex-start` (trust it in `/hooks`; checked against codex-cli 0.166.0, which knows the event) |

Only `UserPromptSubmit` is used: it fires for every prompt, first or follow-up, whereas `SessionStart` fires once per session and misses follow-up turns. The hook prints nothing (Claude would inject stdout into the conversation), never fails, makes no network call and sends no ping.

What it does, in a worktree with a `.grokbot` file:

1. Synchronously, writes the current time to `<state>/<key>.turn_started` (`<key>` is the SHA-256 of the worktree path). The Stop hook writes `<key>.turn_ended` the same way, with the time the hook fired, so the order of the two never depends on worker queueing. A turn is *open* when `turn_started > turn_ended` (both in microseconds, so a quick start and Stop still order correctly). Registry writes carry the same time, so a delayed worker never overwrites the row of a newer start or end. The transcript path the hook receives is saved too (`<key>.transcript`); the quiet-harness check counts it as activity, which a first turn needs because no Stop has recorded one yet.
2. In the background, under the sweep lock: adds the worktree to `markers.tsv` and writes the registry row: status `running`, `started_at`, harness, session, and the thread id through the usual resolver (`T3CODE_THREAD_ID`, T3 database, stored id; the `t3 thread show` check is cached for 10 minutes). Unlike a Stop, it does not start a sweep. The row keeps showing `running` through sweeps and approval pings until the status file is rewritten or the turn ends; the Stop hook sets the real status and clears `started_at`.

**The first prompt.** A thread writes `.grokbot` with its first command, after its first prompt, so the hook finds no marker. In a T3 worktree (`T3CODE_THREAD_ID` set, or the path is under `$T3CODE_HOME/worktrees/`, default `~/.t3/worktrees/`) it saves `<state>/pending/<key>` (worktree, time, thread id, harness, session, transcript path) instead; anywhere else it does nothing. Every worker run adopts pending notes whose worktree now has a `.grokbot` (turn start, markers and registry as above) and drops those whose turn already ended, or that are 24 hours old. Stop removes its worktree's note. Cost: one marker file write per prompt, no polling; the price is that a first-turn death is only noticed when some hook runs or the launchd sweep does.

**Dead turns in the sweep.** For a marked worktree with an open turn, the sweep takes the later of the turn start and the status file's mtime, and once that is `GROKBOT_STALL_MINUTES` old (default 45, also settable in `~/.grokbot-hooks/config`) it looks for a harness with the same `pgrep`/`lsof` check as below:

- **None running:** one `stalled <N>m turn_died <last status>` ping (`no_status` if there is no status file), whatever the status word is, `done` and `waiting` included. It is recorded as `<key>.turndead` (the turn start time), so each dead turn pings once, even if the status file changes later; a new turn start makes a new dead turn possible. The registry row shows `stalled`.
- **A harness is running:** nothing new. The existing rules below apply, including `approval?` and the exclusions for `done`, `failed`, `needs_input`, `idle`; `waiting` follows its own reminder. An interrupted turn (Esc fires no Stop) with the session still open is therefore not flagged.
- **The check fails** (`pgrep` or `lsof` error): no ping.

Worktrees without a recorded turn start (older installs, hooks not registered) behave exactly as before.

## Approval-prompt pings

A thread blocked on a permission prompt has not ended its turn, so Stop never fires and the sweep used to see it as busy. Two extra events ping while the prompt is open:

| Harness | Event | Command | Fires |
| --- | --- | --- | --- |
| Claude Code | `Notification` | `notify.sh claude-notify` | About 6 seconds after a permission prompt appears (`notification_type: permission_prompt`) |
| Codex | `PermissionRequest` | `notify.sh codex-permission` | When Codex is about to ask for approval |

Both send the usual payload with status `needs_input approval <summary>` (summary: one line, at most 200 bytes) and they:

- **Always ping.** No dedupe, like `needs_input`. They never read or write `.grokbot-status` or the dedupe cache, so the thread's own status is unchanged.
- **Find the marker** in the hook's `cwd` or any parent up to the git toplevel. If the marker is gone but the worktree is in `markers.tsv`, they still ping. With neither, a delegated or agent-launched T3 thread is [routed to its parent's bot](#routing-for-marker-less-threads-and-the-pending-approvals-sweep).
- **Never block the harness.** Everything after reading stdin runs detached; curl has a 10-second timeout; nothing is printed and the exit code is 0. The Codex handler prints no decision, so Codex still shows its own prompt.
- **Claude summary:** the command of the last `tool_use` in the transcript (`Bash: npm publish`) when it can be read, else the notification message (`Claude needs your permission to use Bash`). The transcript is only read for this one line and is never sent.
- **Codex summary:** `tool_name: tool_input.description`, or the command when there is no description. Commands can contain secrets, so the summary is cut to 200 bytes and goes only to the bot's own webhook; log lines hold the first 80 bytes of status.

Claude `notification_type` values that count as approval or input: `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`. Everything else (`idle_prompt`, `auth_success`, `quota_*`, `agent_completed`, ...) is ignored; `idle_prompt` means the turn already ended, which the Stop ping covers. Claude versions that send no type are matched on a message containing "permission".

**Codex `notify`:** Codex's `notify` setting supports only `agent-turn-complete`; `approval-requested` exists only for its built-in TUI notifications. Use the `PermissionRequest` hook instead. It may also fire for requests that Codex's auto-review then approves, so an occasional ping needs no action.

Checked on 2026-11-04 against the [Claude hooks reference](https://code.claude.com/docs/en/hooks) and the [Codex hooks reference](https://developers.openai.com/codex/hooks); the installed codex-cli 0.166.0 binary knows the `PermissionRequest` event.

### Stall fallback in the sweep

Hooks can miss a prompt (older harness, hook not trusted, config dir not registered). The sweep (`notify.sh --sweep`, and the background sweep every hook run starts) has two stall pings. Both use `GROKBOT_STALL_MINUTES` (default `45`), the same age rule (newer of the status-file mtime and the last successful ping) and the same one-attempt-per-status-revision dedupe:

- **No harness running:** `stalled <N>m <original status>`, N being the real age.
- **A harness is running** in the worktree (or a subdirectory) but it has gone quiet: `stalled <N>m approval? <original status>`. Extra conditions:
  1. The status word is not `failed`, `needs_input` or `idle` (`done` and `waiting` are excluded for both variants). Those were pinged at turn end, and an idle open session is normal. So `milestone ...`, `continuing`, no status file and other words qualify.
  2. For `GROKBOT_STALL_MINUTES` none of these changed: any file in the worktree except `.git` and `node_modules` (so build output counts, which spares long builds), the git `index`, `HEAD` and `logs/HEAD`, the newest Claude session log in `~/.claude*/projects/<worktree path>/`, and the transcript path saved by the last Stop ping.

For the `approval?` variant `N` is the threshold ("at least N minutes"), because the age rule can overstate the quiet time. New activity from a running harness clears the revision's stall flag, so a second stall with the same status text pings again. A long task that writes no files and no session log for 45 minutes (a silent test run, say) can still false-positive once; raise `GROKBOT_STALL_MINUTES` for such projects. A thread blocked after a turn that wrote `done` is not flagged by `approval?`; the approval hooks cover that case, and a dead turn is covered by `turn_died`. Harness detection is the `pgrep` plus `lsof` check described in the README; if it fails, the sweep sends neither variant.

## Routing for marker-less threads and the pending-approvals sweep

On 2026-11-10 two builder threads that an orchestrator had started with `delegate_task` waited more than 30 minutes on Claude Code permission prompts and nobody was pinged. The `Notification` hook ran and was registered in the right config dir (`~/.claude-vmg`, set as `homePath` of that T3 provider), but the builders' worktrees had no `.grokbot` marker: only the orchestrator's did. The hook logged `claude-notify no-marker <worktree>` and exited, as designed. Two changes make that case loud.

### Routing a prompt in a thread without a marker

When an approval ping finds neither a marker nor a `markers.tsv` entry, it asks T3 which thread this is and who its parent is. In order:

1. The thread: `T3CODE_THREAD_ID` from the hook's environment (Claude Code), else a lookup by worktree path (Codex).
2. The parent chain: T3 stores `lineage.parentThreadId` for every thread, and `delegate_task` sets it to the thread that called it (`relationshipToParent: "subagent"`). The hook walks up (at most 6 levels) to the first thread whose worktree has a `.grokbot` marker or `markers.tsv` entry, or whose thread id has a row in `threads.sqlite`. That thread's bot gets the ping, with `route: "parent"` and the `sub_thread_*` and `parent_*` payload fields.
3. Fallback, for a thread an agent launched over MCP (`createdBy: agent`, `creationSource: mcp`) without a bot-owned ancestor: the bot with the newest registry row in the same T3 project, `route: "project"`. Threads you started in the T3 window or on your phone (`createdBy: user`) never use it, so your own sessions do not ping a bot.

A bot only counts when it has a webhook file (`~/.grokbot-hooks/<bot>.env`). Nothing is written to the routed worktree: no marker, no `markers.tsv` line, no registry row. `notify.log` shows `<harness> route=parent bot=<bot> sub=<id> parent=<id> <worktree>` for each routed ping, and `no-marker` when nothing matched. Only approval pings and the sweep below route this way; Stop and dead-turn handling still need the marker, because T3 already reports a delegated thread's finished turn to the thread that delegated it.

The source for both lookups is T3's own data: the database lookup the registry already uses (`orchestration_v2_projection_threads`, `payload_json.lineage`), then `t3 thread show --json` (fields `parentThreadId`, `createdBy`, `creationSource`, `projectId`, `worktreePath`). Both are T3 internals that can change; if both fail the ping falls back to `no-marker` as before. `GROKBOT_ROUTE_PARENT=0` and `GROKBOT_ROUTE_PROJECT=0` switch the two routes off.

Why not copy the marker at delegation time? Nothing in the hooks sees a delegation, and a marker written into someone else's worktree could outlive its meaning. Why not parse the delegated thread id? It carries only an opaque command id; the parent is not in it.

### The pending-approvals sweep

T3 keeps every approval prompt and question that is waiting for a human (`orchestration_v2_projection_runtime_requests`, `status = 'pending'`; `t3 thread show` reports the count as `pendingRequestCount`). On every sweep (each hook run in the background, and the launchd sweep) the hooks read that table read-only and, for each request that

- is older than `GROKBOT_APPROVAL_MINUTES` (default `10`; `0` turns this off) and not older than 48 hours,
- belongs to a thread that is not archived or deleted,
- has a bot (its own marker, else the routes above),

send one ping: status `stalled <N>m approval_pending <kind>`, `harness: "sweep"`, `thread_id` of the blocked thread, and the `route` fields. It is sent once per request (state in `state/approvals/`, keyed by a hash of the request id). Marked threads get it too, as a reminder after the immediate `needs_input approval` ping. A request with no bot is logged once as `sweep no-route approval thread=<id>`. A failed send is tried again by later sweeps, three attempts in all. A run sends at most 5 pings. The sweep does not touch the status-based stall state of any worktree.

This is the safety net for prompts that no hook reported: a harness whose config dir has no hook registered, a hook that failed, or a provider that sends no event.

## What the script does

`hooks/notify.sh <harness>`:

1. Reads the hook JSON from stdin and takes `cwd` from it (falls back to the current directory).
2. Finds the git worktree root for that directory.
3. If there is a `.grokbot` file at the root:
   - Reads the bot name from its first line. Only `a-z`, `0-9`, `-` and `_` are kept, so the name can only point at a file inside `~/.grokbot-hooks`.
   - Records `worktree<TAB>bot` in `~/.grokbot-hooks/markers.tsv` (mode 600, one line per worktree, at most 500 lines, rewritten only when something changed).
   - Reads up to 2000 bytes of `.grokbot-status`, or uses `turn_ended_no_status` if the file is missing.
4. If there is no `.grokbot` file:
   - If `markers.tsv` has an entry for this exact path, the worktree was removed or the session is running in an old path. It uses that bot and the status `worktree_missing <path> ...`.
   - Otherwise it logs `no-marker <path>` and exits. Nothing is sent.
5. Writes one line to `~/.grokbot-hooks/notify.log`.
6. Loads `~/.grokbot-hooks/<bot>.env`. If it is missing, stops here.
7. POSTs the payload in the background with a 10-second timeout, and logs the HTTP status code.

It never prints to stdout and always exits 0, so it cannot block or change the agent's turn. It also rotates `notify.log` once it passes about 1 MB.

### Why the marker map exists

Two real failures led to `markers.tsv`:

1. **A thread removed its own worktree during cleanup.** When that turn ended, the `.grokbot` marker was already gone, so no callback fired.
2. **A thread was reused for a new task in a new worktree.** The harness session's working directory stayed on the old, deleted path, so the hook never saw the new marker.

Both were silent, because a no-marker run was only logged in debug mode. Now the hook remembers every marked worktree, still reports a known one as `worktree_missing`, and always logs unknown no-marker runs. The two working rules in [grokbot-side.md](grokbot-side.md) keep these cases rare in the first place.

## Payload

```json
{
  "event": "t3_turn_ended",
  "bot": "codexbot",
  "harness": "codex",
  "worktree": "/path/to/the/worktree",
  "cwd": "/path/to/the/worktree/src",
  "session_id": "example-session-id",
  "transcript_path": "/path/to/local/transcript.jsonl",
  "branch": "feat/some-branch",
  "status": "done\nOpened PR, tests pass.",
  "last_message": "Last assistant message, up to 1500 bytes. Empty if the harness does not provide it.",
  "ended_at": "2026-10-31T12:54:01+0800",
  "thread_id": "T3 thread id, or empty",
  "thread_title": "Fix the login redirect",
  "project_id": "T3 project id, or empty",
  "thread_source": "env",
  "my_open_threads": ["<thread id>|done|feat/some-branch|Fix the login redirect"],
  "my_open_threads_more": 0
}
```

| Field | Meaning |
| --- | --- |
| `event` | Always `t3_turn_ended`, including plain CLI callbacks, for compatibility. |
| `bot` | Bot name from the `.grokbot` marker. |
| `harness` | The argument the hook was called with: `codex`, `claude`, `unknown`, `claude-notify`, `codex-permission`, or `sweep`. |
| `worktree` | Absolute path of the worktree root. |
| `cwd` | Original hook working directory, with `$PWD` fallback. Not normalized to the git root. Empty for sweeps. |
| `session_id` | Harness session ID from stdin, not a T3 thread ID. Empty if missing or not a string. |
| `transcript_path` | Local transcript path from stdin; empty if missing, null, or not a string. Contents are never sent. |
| `branch` | Current branch of the worktree. |
| `status` | See the status table below. |
| `last_message` | `last_assistant_message` from either harness; empty if absent. |
| `ended_at` | Local time the hook ran, with UTC offset. |
| `thread_id` | The T3 thread behind this worktree. Empty when it could not be found; fall back to `branch` and `worktree`. Plain Claude Code and Codex CLI sessions have no T3 thread, so it is empty there. |
| `thread_title`, `project_id` | Title and T3 project id of that thread. Empty when unknown. |
| `thread_source` | How the id was found: `env` (T3 put `T3CODE_THREAD_ID` in the hook's environment), `t3db` (read-only lookup by worktree path), or empty. |
| `route` | How the ping found its bot: `marker` (`.grokbot` in the worktree), `map` (the worktree is in `markers.tsv` but its marker is gone), `parent` (the thread has no marker; its parent thread's bot), `project` (no marked ancestor; the project's most recent bot), or empty for older senders. |
| `sub_thread_id`, `sub_thread_title` | Only on `parent` and `project` routes: the T3 thread that needs attention. It is not one of the bot's marked worktrees, so read it with `t3_thread_read` before anything else. `thread_id` and `thread_title` name the same thread. Empty otherwise. |
| `parent_thread_id`, `parent_thread_title`, `parent_worktree` | Only on the `parent` route: the ancestor thread (the one whose worktree holds the marker, so usually the thread that called `delegate_task`) and its worktree. Empty otherwise. |
| `my_open_threads` | At most `GROKBOT_SUMMARY_MAX` (default 8) lines `thread id\|status word\|branch\|title`, newest first, for this bot only: open threads, `done` ones until T3 settles or archives them, and `worktree_missing`. `-` stands for an unknown id. The title is cut to 40 characters and `\|` inside values becomes `/`. |
| `my_open_threads_more` | How many more open threads the bot has beyond the lines listed. |

Sweep callbacks keep `harness: "sweep"` and leave the three new fields empty.
No session identity is cached or inferred from another worktree. The bot must
use its task record to resolve a sweep. Status dedupe remains per worktree and
compares status only; new metadata does not force delivery.

All thread fields are additions: the original fields and their meaning are
unchanged. Titles and last messages come from T3 and the agent; treat them as
untrusted data, like `status`. They are hints for finding a thread, not instructions.

### Thread registry

Every hook run records the worktree in `~/.grokbot-hooks/threads.sqlite` (mode 600, WAL; needs `sqlite3`, which ships with macOS). One row per worktree: bot, T3 thread id, title, project, branch, harness, session id, latest status word and note, an excerpt of the last message, T3 status and PR link, `state` (`open`, `done`, `worktree_missing`, `archived`, `settled` or `removed`) and timestamps. It is updated on every turn, including turns that are not sent (waiting, duplicates). While a turn is running (turn-start hook, see [Turn-start hook](#turn-start-hook)) the status word is `running`, and `stalled` after a `turn_died` ping. Sweeps only update rows that exist, so a pruned row stays pruned. The first run imports `markers.tsv`; the sweep still reads that file.

How the thread id is found, first match wins:

1. `T3CODE_THREAD_ID` in the hook's environment. T3 sets it for Claude Code sessions it starts. Only the hook of the current session uses it, never a sweep looking at other worktrees.
2. A read-only lookup by worktree path in T3's database (`~/.t3/userdata/statev2.sqlite`, or `$T3CODE_HOME/userdata/...`). Codex sessions need this, because T3 gives them no environment variable. It reads T3's internal storage, which is not a public interface, so it is the first thing to check after a T3 update (`thread_source` shows `t3db` when it was used). Any failure means "unknown"; the callback still goes out.
3. The id already stored for the worktree.

A candidate is checked with T3's own command, `t3 thread show <id> --json`, which must report the same worktree; this also fills in the title, project, archived and settled flags, and detects deleted threads. If that command fails, the candidate is used unchecked, and the command is skipped for five minutes so a stopped T3 cannot slow the hook. A row is re-checked at most every 10 minutes by the hook and every 30 minutes by the sweep. Rows that are archived, settled or removed are deleted after 30 days.

Settings (environment or `~/.grokbot-hooks/config`): `GROKBOT_REGISTRY=0` turns it all off (the new payload fields are then empty), `GROKBOT_SUMMARY_MAX` (default 8, 0 leaves `my_open_threads` empty), `GROKBOT_T3_CLI`, `GROKBOT_T3_DB`, `GROKBOT_T3_DB_LOOKUP=0` (never read T3's database), and for [routing and pending approvals](#routing-for-marker-less-threads-and-the-pending-approvals-sweep) `GROKBOT_ROUTE_PARENT=0`, `GROKBOT_ROUTE_PROJECT=0` and `GROKBOT_APPROVAL_MINUTES`. Look at it by hand with `sqlite3 -readonly ~/.grokbot-hooks/threads.sqlite 'select bot,state,status_word,thread_id,title from threads order by updated_at desc limit 20'`. The file is safe to delete; it is rebuilt from `markers.tsv` and from later turns. `notify.log` shows `registry-error` lines when something failed.

### Status values

| First word of `status` | Meaning |
| --- | --- |
| `done` | The agent says the work is finished. The rest is its note, usually with the PR URL. |
| `needs_input` | The agent needs a decision. The rest is the question and options. |
| `failed` | The agent is stuck. The rest says what blocked it. |
| `stalled` | No status change or successful ping for 45 minutes (override: `GROKBOT_STALL_MINUTES`), with no running harness. One attempt per revision. |
| `turn_ended_no_status` | The worktree has a marker but no `.grokbot-status`. Read the thread. |
| `needs_input approval <summary>` | Mid-turn: the harness is blocked on an approval or input prompt. Sent by `claude-notify` / `codex-permission`, harness field is that mode name. A bot cannot answer it; tell the human. |
| `stalled <N>m turn_died <status>` | Sweep only: a turn started (turn-start hook) and never ended, no harness is running, and nothing changed for N minutes (default 45). Sent even if the old status was `done` or `waiting`. Once per dead turn. `<status>` is the worktree's last status text, `no_status` if there is none. Treat like `failed`. See [Turn-start hook](#turn-start-hook). |
| `stalled <N>m approval_pending <kind>` | Sweep only (`harness: "sweep"`): T3's own list shows a request of that `kind` (`command`, `user_input`, ...) waiting for a human for N minutes. Once per request. See [pending approvals](#routing-for-marker-less-threads-and-the-pending-approvals-sweep). |
| `stalled <N>m approval? <status>` | Sweep only (`harness: "sweep"`): a harness is running but nothing has changed for N minutes; it may be blocked on an approval prompt. `<status>` is the worktree's last status text. |
| `worktree_missing` | The worktree is known from `markers.tsv` but has no marker now (removed, or the session's cwd is an old path). The full text is `worktree_missing worktree <path> no longer has a .grokbot marker (deleted or moved); read the thread for its real state`. `branch` is usually empty. Read the thread. |

Request headers: `Content-Type: application/json` and, if set, `Authorization: <value from set-webhook.sh>`.

## Testing and debugging

Watch the log while a thread runs:

```bash
tail -f ~/.grokbot-hooks/notify.log
```

Turns in folders with no marker and no entry in `markers.tsv` are always logged as `no-marker <path>`. The `debug` file from earlier versions is no longer needed.

What the log lines mean:

| Line | Meaning |
| --- | --- |
| `... codex no-marker /path` | Hook ran, but the folder has no `.grokbot` and is not in `markers.tsv`. Normal for your own sessions. For a bot thread, it means the marker was never written, or the session is in a path the hook has never seen. |
| `... status=worktree_missing worktree /path ...` | Known worktree, marker gone. The bot was notified and should read the thread. |
| `... codex bot=codexbot branch=... status=done` | Hook ran in a bot worktree. |
| `... codexbot webhook http=200` | Callback delivered. |
| `... codexbot webhook http=401` | Wrong or missing Authorization value. Run `set-webhook.sh` again. |
| `... codexbot webhook http=000` | Could not connect (offline, wrong URL). The curl error is on the line above. |
| a `status=` line but no `webhook` line | No `~/.grokbot-hooks/<bot>.env` for that bot name. |
| nothing at all | The hook did not run. For Codex, check `/hooks` and test in a new thread. |

You can also run the script by hand inside a worktree that has a marker:

```bash
cd /path/to/worktree
echo '{"cwd":"'"$PWD"'","last_assistant_message":"test"}' | ~/.grokbot-hooks/notify.sh codex
tail -n 2 ~/.grokbot-hooks/notify.log
```

This sends a real callback, so the bot will wake up.

To see which worktrees the hook knows about:

```bash
cat ~/.grokbot-hooks/markers.tsv
```

It is safe to delete this file. It is rebuilt as marked worktrees end turns. `threads.sqlite` (see [Thread registry](#thread-registry)) holds the T3 thread behind each worktree.


The sweep can send `stalled <minutes>m <original status>` after 45 minutes
without a status change or successful ping (`GROKBOT_STALL_MINUTES` overrides
the threshold). For plain stalls it excludes `done`, uses the separate two-hour reminder for
`waiting`, and skips worktrees with a running harness. It attempts one stall
ping per status revision. The exception is `stalled <minutes>m turn_died <status>`:
a turn that started but never ended with no harness left is reported even when
the old status was `done` or `waiting`, once per dead turn. Read the thread before taking action. Agents must
write their normal status; `stalled` is generated by the sweep.
