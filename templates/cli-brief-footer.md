# Plain CLI brief footer

Replace `<bot-name>`, then append this to the task given to `claude` or `codex`.

---

First, at the worktree root:

```bash
printf '%s\n' '<bot-name>' > .grokbot
printf '%s\n' '.grokbot*' >> "$(git rev-parse --git-common-dir)/info/exclude"
```

Before ending each turn, overwrite `.grokbot-status` with one line:

- `done <result or PR URL>` when the requested work and review are complete.
- `needs_input <question and options>` when a decision is required.
- `failed <reason>` when the task cannot continue.
- `milestone <completed step>` for a useful progress update.
- `idle` when there is no active work.
- `waiting <what>` only when an external event or human will resume you.

Include a task-specific note. Do not write secrets in status. If a decision is
needed, write `needs_input` and end the turn. The callback notifies the bot; it
does not itself continue this process. Stay in this worktree and do not remove
it. A new task needs a new session. Do not commit the marker or status file.
