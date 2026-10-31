#!/bin/bash
# Install the Grok Bot turn-end hook for Codex and Claude Code.
# Safe to run more than once: it only adds the Stop entry if it is not already there,
# and backs up a config file (<file>.bak-grokbot-<timestamp>) only when it is about to change it.
set -euo pipefail

for bin in jq git curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: $bin is required but not on PATH" >&2; exit 1; }
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.grokbot-hooks"
NOTIFY="$DEST/notify.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"

# 1. Copy the scripts.
mkdir -p "$DEST"
chmod 700 "$DEST"
cp "$SRC/hooks/notify.sh" "$SRC/hooks/set-webhook.sh" "$DEST/"
chmod 700 "$DEST/notify.sh" "$DEST/set-webhook.sh"
echo "Installed scripts to $DEST"

backup() {
  [ -f "$1" ] && cp -p "$1" "$1.bak-grokbot-$STAMP" && echo "  Backed up $1 to $1.bak-grokbot-$STAMP"
  return 0
}

# add_stop_hook <file> <entry-json>
# Appends {"hooks":[entry]} to .hooks.Stop unless a Stop hook already runs grokbot-hooks/notify.sh.
add_stop_hook() {
  local file="$1" entry="$2" tmp
  if jq -e '[.hooks.Stop[]?.hooks[]?.command // empty | select(contains("grokbot-hooks/notify.sh"))] | length > 0' "$file" >/dev/null; then
    echo "  Stop hook already present in $file, leaving it alone"
    return
  fi
  backup "$file"
  tmp="$(mktemp)"
  jq --argjson entry "$entry" '.hooks = (.hooks // {}) | .hooks.Stop = ((.hooks.Stop // []) + [{hooks: [$entry]}])' "$file" > "$tmp"
  cat "$tmp" > "$file"   # keep the original file's permissions
  rm -f "$tmp"
  echo "  Added Stop hook to $file"
}

# 2. Codex: ~/.codex/hooks.json (created if missing).
CODEX_HOOKS="$HOME/.codex/hooks.json"
echo "Codex:"
mkdir -p "$HOME/.codex"
if [ ! -f "$CODEX_HOOKS" ]; then
  echo '{"hooks":{}}' > "$CODEX_HOOKS"
  echo "  Created $CODEX_HOOKS"
fi
add_stop_hook "$CODEX_HOOKS" "$(jq -n --arg cmd "$NOTIFY codex" \
  '{type:"command",command:$cmd,timeout:15,statusMessage:"Notifying Grok Bot"}')"

# 3. Claude Code: ~/.claude/settings.json (only if Claude Code is set up on this machine).
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
echo "Claude Code:"
if [ -d "$HOME/.claude" ]; then
  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    echo '{}' > "$CLAUDE_SETTINGS"
    echo "  Created $CLAUDE_SETTINGS"
  fi
  add_stop_hook "$CLAUDE_SETTINGS" "$(jq -n --arg cmd "$NOTIFY claude" \
    '{type:"command",command:$cmd,timeout:15}')"
else
  echo "  ~/.claude not found, skipping (run install.sh again after installing Claude Code)"
fi

cat <<NEXT

Next steps:
  1. Codex only runs hooks you have trusted. Run: codex
     then type /hooks and trust the "Notifying Grok Bot" Stop hook.
     Sessions that were already running keep their old hooks, so test in a new thread.
  2. For each bot, create a "T3 callback" webhook routine in Grok Bot, then run:
       $DEST/set-webhook.sh <bot-name>
     and paste the URL and the Authorization header value when asked.
  3. Optional, while testing: touch $DEST/debug  (logs every turn to $DEST/notify.log)
NEXT
