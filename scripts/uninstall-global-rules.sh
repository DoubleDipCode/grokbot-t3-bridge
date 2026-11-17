#!/bin/bash
# Stop the launchd sync and remove its script. Leaves the rules files alone: ~/.claude/CLAUDE.md keeps
# its import, ~/.codex/AGENTS.md stays as last generated. To go back to the old hand-kept files copy
# ~/.claude/CLAUDE.md.bak-pre-sync and ~/.codex/AGENTS.md.bak-pre-sync over them.
set -euo pipefail
LABEL=com.grokbot.sync-global-rules
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.grokbot-hooks/sync-global-rules.sh"
echo "Removed the launchd agent and the installed sync script."
