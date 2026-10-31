# Brief footer

Append this to every brief a bot sends to T3. Replace `<bot-name>` with the bot's name as used in `set-webhook.sh` (lowercase letters, digits, `-`, `_`).

---

**Callback setup (do this first, before anything else):**

```bash
echo '<bot-name>' > .grokbot
echo '.grokbot*' >> "$(git rev-parse --git-common-dir)/info/exclude"
```

Run these at the root of this worktree. The second line keeps the marker and status files out of git. Never commit them.

**Before you end every turn,** overwrite `.grokbot-status` at the worktree root. The first line is exactly one of `done`, `needs_input` or `failed`. After that, add a short note:

- `done`: the work is finished, the review step has run, and the PR is open. Include the PR URL.
- `needs_input`: you need a decision. Write the question and the options.
- `failed`: you are stuck. Write what you tried and what blocked you.

Example:

```bash
printf 'needs_input\nShould the export include archived rows? Options: (a) yes, (b) no, (c) behind a flag.\n' > .grokbot-status
```

**If you need a decision, write `needs_input` and end your turn.** Do not wait inside the thread for an answer. The answer will come as a new message in this thread.

**Never remove this worktree yourself,** not even at the end. Do not run `git worktree remove` on it or delete its folder. Cleanup happens after your final turn.

**Stay on this task in this worktree.** If you are asked to start an unrelated task, say so and end the turn with `needs_input`. It needs a new thread.
