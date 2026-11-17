#!/bin/bash
# Set up the shared global rules: ~/.agents/global-rules.md is the one file to edit; Claude Code
# imports it, and ~/.codex/AGENTS.md is rebuilt from it by sync-global-rules.sh, which a launchd
# agent runs whenever one of the files changes. Safe to run again.
#
# What it does: backs up CLAUDE.md and AGENTS.md (*.bak-pre-sync, never overwritten), copies the
# sync script to ~/.grokbot-hooks, writes the launchd agent com.grokbot.sync-global-rules, runs a
# first sync. It never creates the shared file from nothing unless you pass --seed (then it starts
# from the current AGENTS.md, or CLAUDE.md, and you must review it).
# Nothing is touched when HOME points somewhere else, apart from that HOME (used by the tests).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.grokbot-hooks"
SHARED="${GLOBAL_RULES_FILE:-$HOME/.agents/global-rules.md}"
AGENTS="${CODEX_AGENTS_FILE:-$HOME/.codex/AGENTS.md}"
CLAUDE="${CLAUDE_MD_FILE:-$HOME/.claude/CLAUDE.md}"
CODEX_ONLY="${GLOBAL_RULES_CODEX_ONLY:-$HOME/.agents/codex-only.md}"
LABEL=com.grokbot.sync-global-rules
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SEED=0; NO_LAUNCHD="${GLOBAL_RULES_NO_LAUNCHD:-0}"
for a in "$@"; do case "$a" in --seed) SEED=1 ;; --no-launchd) NO_LAUNCHD=1 ;; *) echo "unknown option $a" >&2; exit 1 ;; esac; done

# 1. Backups (first run only: an existing .bak-pre-sync is the pre-sync original and is kept).
for f in "$CLAUDE" "$AGENTS"; do
  if [ -f "$f" ] && [ ! -e "$f.bak-pre-sync" ]; then cp -p "$f" "$f.bak-pre-sync"; echo "Backed up $f to $f.bak-pre-sync"; fi
done

# 2. The shared file.
mkdir -p "$(dirname "$SHARED")"
if [ ! -f "$SHARED" ]; then
  [ "$SEED" = 1 ] || { echo "error: $SHARED does not exist. Create it with the rules both tools should follow, or run with --seed." >&2; exit 2; }
  if [ -f "$AGENTS" ]; then
    # Drop the generated-file header if a previous run left one.
    awk 'BEGIN{h=1} h && /^<!-- GENERATED FILE/ {skip=1} skip { if (/-->$/) {skip=0; h=0}; next } {h=0; print}' "$AGENTS" | cat -s > "$SHARED"
  elif [ -f "$CLAUDE" ]; then grep -vE '^@' "$CLAUDE" > "$SHARED"; else : > "$SHARED"; fi
  echo "Seeded $SHARED. Review it and add any rule that only the other tool's file had."
fi

# 3. CLAUDE.md that still holds its own rules: replace it by the import only when every line is in the shared file.
IMPORT="@$(printf '%s' "${SHARED/#$HOME/~}")"
if [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] && ! grep -qxF "$IMPORT" "$CLAUDE"; then
  missing="$(grep -v '^[[:space:]]*$' "$CLAUDE" | grep -vxFf "$SHARED" || true)"
  if [ -n "$missing" ]; then
    echo "error: $CLAUDE has $(printf '%s\n' "$missing" | wc -l | tr -d ' ') line(s) that are not in $SHARED." >&2
    echo "Add them to $SHARED (or to Claude-only lines below an import line you add yourself), then run again. Nothing was changed except the backups." >&2
    exit 3
  fi
  : > "$CLAUDE.tmp-sync"; chmod 600 "$CLAUDE.tmp-sync"; mv -f "$CLAUDE.tmp-sync" "$CLAUDE"   # emptied; sync writes the import header
fi

# 4. Scripts, then a first sync.
mkdir -p "$DEST"; chmod 700 "$DEST"
cp "$SRC/sync-global-rules.sh" "$DEST/sync-global-rules.sh"; chmod 700 "$DEST/sync-global-rules.sh"
echo "Installed $DEST/sync-global-rules.sh"
/bin/bash "$DEST/sync-global-rules.sh"
echo "Synced: $CLAUDE imports $SHARED, $AGENTS rebuilt."

# 5. launchd: run the sync when any of the four files changes, at load, and every 30 minutes as a net.
if [ "$NO_LAUNCHD" = 1 ] || [ "$(uname)" != Darwin ]; then echo "Skipped launchd agent."; exit 0; fi
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST.new" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/sync-global-rules.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WatchPaths</key>
  <array>
    <string>$SHARED</string>
    <string>$CODEX_ONLY</string>
    <string>$AGENTS</string>
    <string>$CLAUDE</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
PL
if [ -f "$PLIST" ] && cmp -s "$PLIST.new" "$PLIST"; then rm -f "$PLIST.new"; echo "launchd agent already current."
else mv -f "$PLIST.new" "$PLIST"; launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"; echo "Loaded launchd agent $LABEL."; fi
