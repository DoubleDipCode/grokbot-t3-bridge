#!/bin/bash
# Install the Grok Bot turn-end and approval-prompt hooks for Codex and Claude Code.
# Safe to run more than once: it only adds an entry if the event does not already run notify.sh,
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
cp "$SRC/hooks/notify.sh" "$SRC/hooks/set-webhook.sh" "$SRC/hooks/config-lib.sh" "$DEST/"
chmod 700 "$DEST/notify.sh" "$DEST/set-webhook.sh" "$DEST/config-lib.sh"
echo "Installed scripts to $DEST"
# The optional local config ($DEST/config) is never created or overwritten here.
# shellcheck source=hooks/config-lib.sh
. "$SRC/hooks/config-lib.sh"
grokbot_load_config "$DEST/config"

backup() {
  [ -f "$1" ] && cp -p "$1" "$1.bak-grokbot-$STAMP" && echo "  Backed up $1 to $1.bak-grokbot-$STAMP"
  return 0
}

# add_hook <file> <event> <entry-json>
# Appends {"hooks":[entry]} to .hooks.<event> unless a hook for that event already runs
# grokbot-hooks/notify.sh. Merges into the existing JSON: every other key is kept as is.
# Nothing from the file is printed, since Claude settings can hold secrets.
add_hook() {
  local file="$1" event="$2" entry="$3" tmp
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "  warning: $file is not valid JSON, skipping it (fix it and run install.sh again)" >&2
    return
  fi
  if jq -e --arg ev "$event" '[.hooks[$ev][]?.hooks[]?.command // empty | select(contains("grokbot-hooks/notify.sh"))] | length > 0' "$file" >/dev/null; then
    echo "  $event hook already present in $file, leaving it alone"
    return
  fi
  backup "$file"
  tmp="$(mktemp)"
  jq --arg ev "$event" --argjson entry "$entry" \
    '.hooks = (.hooks // {}) | .hooks[$ev] = ((.hooks[$ev] // []) + [{hooks: [$entry]}])' "$file" > "$tmp"
  cat "$tmp" > "$file"   # keep the original file's permissions
  rm -f "$tmp"
  echo "  Added $event hook to $file"
}

# 2. Codex: ~/.codex/hooks.json (created if missing).
#    Stop pings at turn end; PermissionRequest pings when Codex is about to ask for approval.
CODEX_HOOKS="$HOME/.codex/hooks.json"
echo "Codex:"
mkdir -p "$HOME/.codex"
if [ ! -f "$CODEX_HOOKS" ]; then
  echo '{"hooks":{}}' > "$CODEX_HOOKS"
  echo "  Created $CODEX_HOOKS"
fi
add_hook "$CODEX_HOOKS" Stop "$(jq -n --arg cmd "$NOTIFY codex" \
  '{type:"command",command:$cmd,timeout:15,statusMessage:"Notifying Grok Bot"}')"
add_hook "$CODEX_HOOKS" PermissionRequest "$(jq -n --arg cmd "$NOTIFY codex-permission" \
  '{type:"command",command:$cmd,timeout:15,statusMessage:"Notifying Grok Bot"}')"

# 3. Claude Code: every config dir that exists. Tools that run Claude Code with several accounts or
#    providers set CLAUDE_CONFIG_DIR to a different directory each, so ~/.claude alone is not enough.
#    Dirs used: ~/.claude, $CLAUDE_CONFIG_DIR and every ~/.claude-* directory that has a settings.json.
#    GROKBOT_CLAUDE_DIRS (colon separated, like PATH) replaces that list; GROKBOT_EXTRA_CLAUDE_DIRS adds
#    to it. Both can also be set in $DEST/config (see examples/config.example).
echo "Claude Code:"
grokbot_resolve_claude_dirs
for dir in ${CLAUDE_DIRS_MISSING[@]+"${CLAUDE_DIRS_MISSING[@]}"}; do
  echo "  $dir not found, skipping"
done
for dir in ${CLAUDE_DIRS[@]+"${CLAUDE_DIRS[@]}"}; do
  settings="$dir/settings.json"
  if [ ! -f "$settings" ]; then
    echo '{}' > "$settings"
    echo "  Created $settings"
  fi
  add_hook "$settings" Stop "$(jq -n --arg cmd "$NOTIFY claude" \
    '{type:"command",command:$cmd,timeout:15}')"
  add_hook "$settings" Notification "$(jq -n --arg cmd "$NOTIFY claude-notify" \
    '{type:"command",command:$cmd,timeout:15}')"
done
[ "${#CLAUDE_DIRS[@]}" -gt 0 ] || echo "  no Claude config dir found (run install.sh again after installing Claude Code)"

cat <<NEXT

Next steps:
  1. Codex only runs hooks you have trusted. Run: codex
     then type /hooks and trust the "Notifying Grok Bot" Stop and PermissionRequest hooks.
     Sessions that were already running keep their old hooks, so test in a new thread.
  2. For each bot, create a "T3 callback" webhook routine in Grok Bot, then run:
       $DEST/set-webhook.sh <bot-name>
     and paste the URL and the Authorization header value when asked.
  3. While testing: tail -f $DEST/notify.log  (turns without a marker show up as no-marker)
  4. Optional: tune thresholds or name extra Claude config dirs in $DEST/config
     (copy examples/config.example; install.sh never overwrites it).
NEXT
