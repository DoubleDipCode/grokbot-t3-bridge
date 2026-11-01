# Shared setup for plain CLI sessions

Use this page with either [Claude Code](claude-code.md) or [Codex CLI](codex-cli.md).
No T3 connector is needed. Use one active session per worktree. Record the machine,
OS account, harness, worktree, branch, and session ID in the bot's task record.
The callback does not identify the machine, so use a separate routine per machine
or bind each routine to one known machine.

## Review and install

You need Bash, jq, git, Perl, shasum, and curl on the agent machine.
Read `hooks/notify.sh`, `hooks/set-webhook.sh`, and the selected configuration
before you install them. The [one-shot prompt](../ONE-SHOT-PROMPT.md) can instead
ask your agent to build and show each file for approval.

From this repo, after review:

```bash
mkdir -p "$HOME/.grokbot-hooks"
chmod 700 "$HOME/.grokbot-hooks"
# Back up existing scripts before replacing them.
cp hooks/notify.sh hooks/set-webhook.sh "$HOME/.grokbot-hooks/"
chmod 700 "$HOME/.grokbot-hooks/notify.sh" "$HOME/.grokbot-hooks/set-webhook.sh"
```

Add only the Stop entry in your selected guide. Back up the settings file first.
Merge the entry into the existing `hooks.Stop` array; do not replace other settings
or add a second notify.sh entry. Replace `/absolute/home` in the JSON with your
home path. The escaped quotes around the script path support paths with spaces.
The existing `install.sh` registers both harnesses for the T3 setup; it is not a
single-harness installer. Do not run it for these manual setup steps.

Create a webhook routine in Grok Bot named **CLI callback**. Use
[the CLI routine prompt](../templates/cli-routine-prompt.md). Store its URL and
Authorization header on the agent machine:

```bash
~/.grokbot-hooks/set-webhook.sh mybot
```

Enter credentials in that terminal only. Do not put them in chat or git.

## Start a task

The human can start an interactive session. A bot with authorized shell access to
the same machine and account can start a headless session. Give the agent its task
and [the CLI brief footer](../templates/cli-brief-footer.md). Use a new worktree for
each task, and put the marker at its root. A marked worktree sends callbacks from
all sessions that use it, including a human's session.

Track the session ID from the callback together with the worktree and branch.
For a human-started session, the human must first tell the bot which task and
worktree to expect. Do not adopt an unknown callback as a new authorized task.
Keep CLI session history: a session that was not saved cannot be resumed.

## Continue safely

A Stop callback is a notification, not proof that the process has exited. Other
Stop hooks can also cause more work. Before a headless resume, confirm that the
previous process has exited and that the human has handed over any interactive
session. Serialize resumes per session. Do not run two agents in that worktree.
Use an explicit saved ID, never the most recent session as a shortcut.

This bridge does not steer a live interactive terminal. With no shell access to
the agent machine, the bot can only notify the human and supply a suggested next
prompt. It cannot run a resume command or read local transcripts.

There is no T3 remote thread read, interrupt, or approval UI in this path. The bot
can read captured headless output or local history only when it has access.
Approval prompts are not completed turns. A human must handle interactive
approvals; headless commands can deny tools or fail if permission is absent.
Choose permissions for the task before launch. Do not bypass approvals just to
make callbacks work.

## Status and delivery limits

Use `waiting`, `idle`, `milestone`, `done`, `needs_input`, and `failed` as described
in [the README](../README.md#actionable-status-and-stall-checks). `waiting` needs
an external wakeup or a human who will resume the session. The webhook does not
resume the CLI on its own.

Delivery and dedupe remain per worktree, not per session. Use a unique task note
in the first status if you reuse a worktree; an identical previous status can be
suppressed. Sweeps have `harness: "sweep"` and empty `session_id`, `transcript_path`,
and `cwd`. They have no hook stdin and must not borrow another session's identity.
Resolve them through the bot's task record; if there is no unique match, notify
the human. Never resume from a sweep alone.

The optional [launchd sweep](../README.md#actionable-status-and-stall-checks)
checks waiting worktrees and missing markers. It does not check running processes
or start sessions. Crashes, interrupts, API errors, sleeping machines, and failed
HTTP delivery can produce no callback. Keep a separate, infrequent check of known
tasks, or ask the human to check them. No automatic retry or remote access is
provided here.

Test the script without credentials with `python3 tests/notify-http-test.py`.
After installation and human hook review, use a small marked task to test actual
harness delivery. This sends a real callback to the configured routine.
To remove the setup, remove only its Stop handler from the selected settings
file. Keep other handlers. Remove scripts and credentials only if no other
harness uses them.
