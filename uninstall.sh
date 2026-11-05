#!/bin/bash
# Remove the Grok Bot hook entries (Stop, Notification, PermissionRequest, UserPromptSubmit) from Codex and
# every Claude Code config dir found the same way install.sh finds them. Other keys and other hooks are left alone.
# Leaves ~/.grokbot-hooks (scripts, config, logs and <bot>.env files) in place; delete it yourself if you want.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/config-lib.sh
. "$SRC/hooks/config-lib.sh"
grokbot_load_config "$HOME/.grokbot-hooks/config"

remove_hooks() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "warning: $file is not valid JSON, skipping it" >&2
    return 0
  fi
  if ! jq -e '[.hooks // {} | to_entries[] | .value[]?.hooks[]?.command // empty | select(contains("grokbot-hooks/notify.sh"))] | length > 0' "$file" >/dev/null; then
    echo "No Grok Bot hook in $file"
    return 0
  fi
  cp -p "$file" "$file.bak-grokbot-$STAMP"
  tmp="$(mktemp)"
  # Per event: drop our handler, drop groups left empty, drop the event if left empty.
  # Then drop .hooks itself if nothing is left.
  jq '.hooks |= (to_entries
        | map(.value |= (map(.hooks |= map(select((.command // "") | contains("grokbot-hooks/notify.sh") | not)))
                         | map(select((.hooks | length) > 0))))
        | map(select((.value | length) > 0))
        | from_entries)
      | if .hooks == {} then del(.hooks) else . end' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  echo "Removed Grok Bot hooks from $file (backup: $file.bak-grokbot-$STAMP)"
}

remove_hooks "$HOME/.codex/hooks.json"
grokbot_resolve_claude_dirs
for dir in ${CLAUDE_DIRS[@]+"${CLAUDE_DIRS[@]}"}; do
  remove_hooks "$dir/settings.json"
done
echo "Done. ~/.grokbot-hooks was left in place."
