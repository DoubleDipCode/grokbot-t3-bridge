# Fewer false-alarm approval prompts

The hooks in this repo tell a bot when a thread is blocked on an approval prompt. They do not make the prompt go away, and they never approve anything. This page is about the prompts themselves, for the case where a thread keeps stopping on a command that was harmless.

## What happened on 2026-11-10

Two builder threads (full-access runtime mode, Claude Code) each waited more than 30 minutes on a Claude Code permission prompt. The prompt said `Dangerous rm operation not ruled out`. The commands behind it were long heredocs, `cat > file <<'EOF'` and `python3 - <<'EOF'`, whose bodies only *mentioned* `rm` (in prose, in code being written, in a test fixture). The command itself deleted nothing.

Claude Code's Bash permission check reads the whole command string, including the heredoc body, and when it cannot prove that an `rm` in it is safe it asks instead of guessing. That is the safe behavior and this repo does not try to change it. Full-access mode in T3 did not skip it.

The reason nobody was told is a separate bug, fixed in the same change as this page: see [routing for marker-less threads](hooks.md#routing-for-marker-less-threads-and-the-pending-approvals-sweep).

## Options

Ordered from least to most risky. None of them is applied by `install.sh`; they are settings you choose.

1. **Change how threads write files (recommended, no safety cost).** Tell the agent to write files with its file tool (Write/Edit), to put a script in a file and run that file, and to keep shell commands short. A heredoc is only ever needed because the agent is using the shell as an editor. The brief footer in [templates/brief-footer.md](../templates/brief-footer.md) now says this for every bot-launched thread. For all your own Claude Code sessions, add a line like this to `~/.claude/CLAUDE.md` (and the other Claude config dirs you use, for example `~/.claude-vmg/CLAUDE.md`):

   ```
   Write files with the Write/Edit tools, not with shell heredocs (`cat > file <<'EOF'`, `python3 - <<'EOF'`). Put scripts in a file and run the file. Keep Bash commands short and free of long quoted bodies.
   ```

   This removes the trigger instead of the check. It costs nothing and makes the commands easier to read in the transcript too.

2. **Allow specific, narrow commands in `permissions.allow`** (`~/.claude*/settings.json`, or a project's `.claude/settings.json`). Good for a fixed command you run all the time, for example `Bash(npm run lint)` or `Bash(python3 scripts/check.py:*)` (check the exact pattern syntax of your Claude Code version in `/permissions`). It does not help with heredocs: the allowlist matches the command, and a rule loose enough to match an arbitrary heredoc (`Bash(cat:*)`, `Bash(python3:*)`) allows everything that starts the same way, including the dangerous ones. Do not add rules like that to quiet this prompt.

3. **Rely on the alert and approve by hand.** With the routing and the pending-approvals sweep the bot now messages you within about 10 minutes (the `Notification` hook within seconds), naming the blocked thread and its parent. Approving takes a click in T3. This is the default.

4. **Auto-approve with a hook or a `bypassPermissions`-style mode.** Not recommended and not provided here. A hook that answers `allow` to every Bash prompt turns off the check that exists to stop an unintended `rm -rf`; the 2026-11-10 prompts were false alarms, but the same prompt is what you want in front of a real one.

Whichever you choose, the pings above stay on: they are the safety net for the prompts you did not anticipate.
