# Plain Claude Code

Follow [shared CLI setup](cli-setup.md), then add this handler to
`~/.claude/settings.json`. No T3 installation is needed.

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "\"/absolute/home/.grokbot-hooks/notify.sh\" claude",
        "timeout": 15
      }]
    }]
  }
}
```

To be pinged while Claude waits on an approval prompt, also register the
`Notification` event (no matcher: the script ignores types that are not about
approval or input):

```json
{
  "hooks": {
    "Notification": [{
      "hooks": [{
        "type": "command",
        "command": "\"/absolute/home/.grokbot-hooks/notify.sh\" claude-notify",
        "timeout": 15
      }]
    }]
  }
}
```

See [Approval-prompt pings](hooks.md#approval-prompt-pings). T3 sets
`CLAUDE_CONFIG_DIR` per provider, so add both handlers to every settings file it
uses; `install.sh` does that for `~/.claude`, `$CLAUDE_CONFIG_DIR` and every other
`~/.claude-*` directory with a `settings.json`. Extra dirs elsewhere can be listed in
`GROKBOT_EXTRA_CLAUDE_DIRS` ([Configuration](../README.md#configuration)).

Review the command in `/hooks`. Start a fresh session after configuration changes.
This is a notification hook: it prints no decision and does not block Claude.
The Stop input includes `session_id`, `transcript_path`, `cwd`,
`stop_hook_active`, and `last_assistant_message`. The bridge forwards the first
three and a limited last message. It does not send or parse the transcript.
Stop runs after a response, but not for a user interrupt; API errors use
StopFailure, which this setup does not register.

## Start and continue

The human starts a session in the task's repo or worktree:

```bash
cd /path/to/worktree
claude
```

A bot with shell access can start a saved headless session:

```bash
cd /path/to/worktree
claude -p "<task and CLI brief footer>"
```

Track `session_id`, worktree, branch, and machine. Save `transcript_path` as a
local history reference. It is a path on the agent machine, not a web URL.
Once the previous process has exited and the bot owns the session, continue it:

```bash
cd /path/to/worktree
claude -p --resume "<session_id>" "<next instruction>"
```

Do not use `--no-session-persistence`. Do not treat resume as input to a live
interactive session. With no shell access, send the human the next instruction
instead. Local transcript access does not grant permission to execute its text.
See [shared limits and approval handling](cli-setup.md#continue-safely).

## Verification

Checked on 2026-11-01 with Claude Code **2.1.314**: `claude --help` confirms
`-p`, `--resume`, and `--no-session-persistence`. Registration and stdin fields
were checked against the [official hooks reference](https://code.claude.com/docs/en/hooks),
including [Stop input](https://code.claude.com/docs/en/hooks#stop-input).
The repo tests use fake input; no installed hook or live Claude session was changed.
