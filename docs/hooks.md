# Turn-end hooks

## Why a hook and not "curl when you're done"

You could put "when you finish, curl this URL" in the brief instead. That has three problems:

- The agent forgets, or stops early on an error, and nothing is sent.
- The webhook URL and key would have to be in the brief, which means in the thread, the transcript and maybe the logs.
- Every brief has to repeat the instructions correctly.

A `Stop` hook is run by the harness at the end of every turn, whether the agent remembers or not. The secret stays in a file on the machine. The agent's only job is to write a one-line status to a file, and if it skips that, the payload says `turn_ended_no_status` and the bot reads the thread.

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

There is no trust step. `last_message` may be empty for Claude Code.

## What the script does

`hooks/notify.sh <harness>`:

1. Reads the hook JSON from stdin and takes `cwd` from it (falls back to the current directory).
2. Finds the git worktree root for that directory.
3. If there is no `.grokbot` file at the root, exits. Nothing is sent and nothing is logged (unless debug is on).
4. Reads the bot name from the first line of `.grokbot`. Only `a-z`, `0-9`, `-` and `_` are kept, so the name can only point at a file inside `~/.grokbot-hooks`.
5. Reads up to 2000 bytes of `.grokbot-status`, or uses `turn_ended_no_status` if the file is missing.
6. Writes one line to `~/.grokbot-hooks/notify.log`.
7. Loads `~/.grokbot-hooks/<bot>.env`. If it is missing, stops here.
8. POSTs the payload in the background with a 10-second timeout, and logs the HTTP status code.

It never prints to stdout and always exits 0, so it cannot block or change the agent's turn.

## Payload

```json
{
  "event": "t3_turn_ended",
  "bot": "codexbot",
  "harness": "codex",
  "worktree": "/path/to/the/worktree",
  "branch": "feat/some-branch",
  "status": "done\nOpened PR, tests pass.",
  "last_message": "Last assistant message, up to 1500 bytes. Empty if the harness does not provide it.",
  "ended_at": "2026-10-31T12:54:01+0800"
}
```

| Field | Meaning |
| --- | --- |
| `event` | Always `t3_turn_ended`. |
| `bot` | Bot name from the `.grokbot` marker. |
| `harness` | The argument the hook was called with: `codex`, `claude`, or `unknown`. |
| `worktree` | Absolute path of the worktree root. |
| `branch` | Current branch of the worktree. |
| `status` | Contents of `.grokbot-status` (first line `done`, `needs_input` or `failed`, then a note), or `turn_ended_no_status`. |
| `last_message` | Codex: `last_assistant_message` from the hook input. May be empty for other harnesses. |
| `ended_at` | Local time the hook ran, with UTC offset. |

Request headers: `Content-Type: application/json` and, if set, `Authorization: <value from set-webhook.sh>`.

## Testing and debugging

Turn on debug logging, which also logs turns in worktrees without a marker:

```bash
touch ~/.grokbot-hooks/debug
tail -f ~/.grokbot-hooks/notify.log
```

What the log lines mean:

| Line | Meaning |
| --- | --- |
| `... codex no-marker /path` | Hook ran, but the worktree has no `.grokbot`. Only logged in debug mode. |
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

Remove debug mode when you are done:

```bash
rm ~/.grokbot-hooks/debug
```
