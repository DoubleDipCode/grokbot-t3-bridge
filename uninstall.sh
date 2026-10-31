#!/bin/bash
# Remove the Grok Bot Stop hook entries from Codex and Claude Code.
# Leaves ~/.grokbot-hooks (scripts, logs and <bot>.env files) in place; delete it yourself if you want.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"

remove_stop_hook() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  if ! jq -e '[.hooks.Stop[]?.hooks[]?.command // empty | select(contains("grokbot-hooks/notify.sh"))] | length > 0' "$file" >/dev/null; then
    echo "No Grok Bot hook in $file"
    return 0
  fi
  cp -p "$file" "$file.bak-grokbot-$STAMP"
  tmp="$(mktemp)"
  # Drop our handler, then drop any Stop group left empty, then drop Stop (and hooks) if left empty.
  jq '.hooks.Stop |= (map(.hooks |= map(select((.command // "") | contains("grokbot-hooks/notify.sh") | not)))
                      | map(select((.hooks | length) > 0)))
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      | if .hooks == {} then del(.hooks) else . end' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  echo "Removed Grok Bot hook from $file (backup: $file.bak-grokbot-$STAMP)"
}

remove_stop_hook "$HOME/.codex/hooks.json"
remove_stop_hook "$HOME/.claude/settings.json"
echo "Done. ~/.grokbot-hooks was left in place."
