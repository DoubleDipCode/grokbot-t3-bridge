# Plain Codex CLI

Follow [shared CLI setup](cli-setup.md), then add this handler to
`~/.codex/hooks.json` (or the active `CODEX_HOME` directory). No T3 installation
is needed.

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "\"/absolute/home/.grokbot-hooks/notify.sh\" codex",
        "timeout": 15,
        "statusMessage": "Notifying Grok Bot"
      }]
    }]
  }
}
```

Codex also accepts inline `[hooks]` configuration in `config.toml`. Use one form
per config layer, since sources are combined. The documented feature key is
`features.hooks`; hooks are enabled by default. Check that your configuration or
managed policy does not disable them.

The human must run `codex`, open `/hooks`, and review and trust the handler.
Do not bypass hook trust. Start a fresh session for the delivery test.
The Stop input uses `session_id`, `cwd`, and `last_assistant_message`.
`transcript_path` can be null. The bridge sends an empty string when it is absent.
This is the Stop stdin interface, not the older `notify` argument interface.
Do not register notify.sh as a `notify` command.

## Start and continue

The human starts an interactive session:

```bash
cd /path/to/worktree
codex
```

A bot with shell access can start a saved headless session:

```bash
cd /path/to/worktree
codex exec "<task and CLI brief footer>"
```

Track the callback's `session_id` with machine, worktree, and branch. It is a
Codex session ID, not a T3 thread ID. Keep the command's output for later review.
After the previous process has exited and the bot owns the session:

```bash
cd /path/to/worktree
codex exec resume "<session_id>" "<next instruction>"
```

Do not use `--ephemeral` for sessions that must resume. Use the same OS account
and Codex home, where the session history and hook trust are stored.
The resume command starts a new invocation; this bridge does not attach to or
steer a running interactive session. Codex has other control interfaces, but
this setup does not configure them. Without shell access, the bot can only
notify the human. See [shared limits and approvals](cli-setup.md#continue-safely).

## Verification

Checked on 2026-11-01 with **codex-cli 0.166.0** using `codex --help`,
`codex exec --help`, and `codex exec resume --help`. The
[official hooks reference](https://developers.openai.com/codex/hooks) confirms
registration, trust, common input fields, and Stop fields. Check these sources
again for older or newer versions. The repo tests use fake stdin and a local
HTTP endpoint; they do not prove live CLI delivery. No installed hook or trust
record was changed.
