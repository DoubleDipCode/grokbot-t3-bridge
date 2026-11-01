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

Review the command in `/hooks`. Claude also provides `last_assistant_message`;
older versions may omit it. This setup does not register StopFailure or interrupt hooks.

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
  "ended_at": "2026-10-31T12:54:01+0800"
}
```

| Field | Meaning |
| --- | --- |
| `event` | Always `t3_turn_ended`, including plain CLI callbacks, for compatibility. |
| `bot` | Bot name from the `.grokbot` marker. |
| `harness` | The argument the hook was called with: `codex`, `claude`, or `unknown`. |
| `worktree` | Absolute path of the worktree root. |
| `cwd` | Original hook working directory, with `$PWD` fallback. Not normalized to the git root. Empty for sweeps. |
| `session_id` | Harness session ID from stdin, not a T3 thread ID. Empty if missing or not a string. |
| `transcript_path` | Local transcript path from stdin; empty if missing, null, or not a string. Contents are never sent. |
| `branch` | Current branch of the worktree. |
| `status` | See the status table below. |
| `last_message` | `last_assistant_message` from either harness; empty if absent. |
| `ended_at` | Local time the hook ran, with UTC offset. |

Sweep callbacks keep `harness: "sweep"` and leave the three new fields empty.
No session identity is cached or inferred from another worktree. The bot must
use its task record to resolve a sweep. Status dedupe remains per worktree and
compares status only; new metadata does not force delivery.

### Status values

| First word of `status` | Meaning |
| --- | --- |
| `done` | The agent says the work is finished. The rest is its note, usually with the PR URL. |
| `needs_input` | The agent needs a decision. The rest is the question and options. |
| `failed` | The agent is stuck. The rest says what blocked it. |
| `turn_ended_no_status` | The worktree has a marker but no `.grokbot-status`. Read the thread. |
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

It is safe to delete this file. It is rebuilt as marked worktrees end turns.
