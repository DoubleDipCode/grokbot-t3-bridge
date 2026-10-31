# The Grok Bot side

Each coding bot needs three things: a webhook routine that receives the callback, briefs that set up the marker and status file, and a quiet backup check.

## 1. A webhook routine per bot

In each coding bot, create a webhook routine named **T3 callback**.

- Use [templates/routine-prompt.md](../templates/routine-prompt.md) as its prompt.
- From the routine panel, copy the webhook URL and the Authorization header value.
- On the machine that runs T3 Code, store them:

  ```bash
  ~/.grokbot-hooks/set-webhook.sh <bot-name>
  ```

  Paste the URL when asked, then the Authorization value. The second prompt hides your input. You can paste either `Bearer ...` or the whole `Authorization: Bearer ...` line.

Use the same `<bot-name>` in the brief footer. One routine, one URL and one key per bot: the marker names the bot, so the callback goes only to the bot that launched the thread.

Do not paste the URL or key into a chat, a brief or a prompt. They only belong in the routine panel and in `~/.grokbot-hooks/<bot>.env`.

## 2. Brief additions

Every brief the bot sends with `t3_thread_launch` ends with [templates/brief-footer.md](../templates/brief-footer.md). It asks the coding agent to:

1. **First step:** write the `.grokbot` marker and exclude it from git:

   ```bash
   echo '<bot-name>' > .grokbot
   echo '.grokbot*' >> "$(git rev-parse --git-common-dir)/info/exclude"
   ```

   `--git-common-dir` matters: in a worktree, `.git` is a file, and `info/exclude` lives in the main repo's git directory.

2. **Before ending every turn:** overwrite `.grokbot-status` with `done`, `needs_input` or `failed` on the first line and a note below.

3. **If it needs a decision:** write `needs_input` and end the turn instead of waiting inside T3. Ending the turn is what fires the hook. A thread that sits and waits never calls back.

Launch with `runtimeMode: "full-access"` and a worktree workspace. See [t3-mcp-setup.md](t3-mcp-setup.md).

## Two working rules

**One thread per task. Never reuse a thread in a new worktree.** A harness session keeps the working directory it was started in. If a bot sends a finished thread a new task and the agent moves to a new worktree, its turns still end with the old path as `cwd`. The hook looks for the marker in the old, often deleted, path and never sees the new one. Launch a new thread for each task instead.

**A thread never removes its own worktree.** If the agent runs `git worktree remove` on its own worktree, the `.grokbot` marker is gone before the turn ends. The bot removes the worktree after the thread's final turn, as described under cleanup below.

The hook has a fallback for both cases: it remembers every marked worktree in `~/.grokbot-hooks/markers.tsv` and reports a known worktree without a marker as `worktree_missing`. That fallback only tells the bot that something ended. Following the rules keeps the normal `done` / `needs_input` / `failed` status working.

## 3. A quiet backup check

The hook only fires when a turn ends. If the harness crashes, the machine sleeps or goes offline, or a thread is stuck on a permission prompt, nothing is sent. A worktree removed before its first turn ended is also invisible to the hook.

Give each bot a low-frequency scheduled routine, for example every one or two hours, that:

- lists the T3 threads it launched that are still open,
- reads the latest message of any thread that has had no activity for a while,
- messages you only if something is stuck, and otherwise stays silent.

Keep it infrequent. It is a safety net, not a replacement for the hook.

## 4. Cleanup after merge

Once the PR is merged and the coding thread has had its final turn, the bot cleans up. The coding thread itself does not do this (see the rules above).

1. Launch a short cleanup thread in the project root (`workspaceStrategy: {"type": "root"}`), with no `.grokbot` marker, and a brief like:

   ```text
   Do not create a .grokbot file. Run:
     git worktree remove <path>        (no --force: stop and report if it is not clean)
     git branch -d <branch>            (lowercase -d: only deletes a merged branch)
   Report what you did and end the turn.
   ```

   Because the cleanup thread has no marker and its folder is not in `markers.tsv`, its turn end is only logged as `no-marker`.
2. Delete the remote branch if GitHub did not already.
3. Settle or archive both threads with `t3_thread_organize`.

Leaving old worktrees around also leaves old `.grokbot` markers around, and any later turn in them would wake the bot again.
