#!/bin/bash
# Installer/uninstaller against a temporary HOME. Touches nothing outside it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset CLAUDE_CONFIG_DIR GROKBOT_CLAUDE_DIRS
mkdir -p "$HOME/.claude" "$HOME/.claude-personal" "$HOME/.claude-vmg" "$HOME/.codex"
# Existing keys (including a fake secret) and an unrelated hook must survive.
echo '{"env":{"TOKEN":"sekret-value"},"hooks":{"Notification":[{"hooks":[{"type":"command","command":"echo other"}]}]},"model":"x"}' > "$HOME/.claude/settings.json"
echo '{"env":{"TOKEN":"sekret-two"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/h/.grokbot-hooks/notify.sh claude"}]}]}}' > "$HOME/.claude-personal/settings.json"
# ~/.claude-vmg has no settings.json yet.
cmds() { jq -r --arg ev "$2" '.hooks[$ev][]?.hooks[]?.command' "$1"; }

OUT="$(bash "$REPO/install.sh" 2>&1)"
case "$OUT" in *sekret*) echo 'FAIL: installer printed a secret'; exit 1 ;; esac
for d in .claude .claude-personal .claude-vmg; do
  f="$HOME/$d/settings.json"
  [ "$(cmds "$f" Notification | grep -c 'grokbot-hooks/notify.sh claude-notify')" = 1 ] || { echo "FAIL: Notification missing in $d"; exit 1; }
  [ "$(cmds "$f" Stop | grep -c 'grokbot-hooks/notify.sh claude$')" = 1 ] || { echo "FAIL: Stop count in $d"; exit 1; }
done
[ "$(jq -r '.env.TOKEN' "$HOME/.claude/settings.json")" = sekret-value ] || { echo 'FAIL: env dropped'; exit 1; }
[ "$(jq -r '.model' "$HOME/.claude/settings.json")" = x ] || { echo 'FAIL: key dropped'; exit 1; }
[ "$(cmds "$HOME/.claude/settings.json" Notification | grep -c 'echo other')" = 1 ] || { echo 'FAIL: other hook dropped'; exit 1; }
[ "$(cmds "$HOME/.codex/hooks.json" PermissionRequest | grep -c 'notify.sh codex-permission')" = 1 ] || { echo 'FAIL: codex PermissionRequest'; exit 1; }
[ "$(cmds "$HOME/.codex/hooks.json" Stop | grep -c 'notify.sh codex$')" = 1 ] || { echo 'FAIL: codex Stop'; exit 1; }
# Idempotent: a second run changes nothing and makes no new backup.
before="$(find "$HOME" -name '*.bak-grokbot-*' | wc -l | tr -d ' ')"
sum1="$(cat "$HOME"/.claude*/settings.json "$HOME/.codex/hooks.json" | shasum)"
bash "$REPO/install.sh" >/dev/null 2>&1
[ "$(cat "$HOME"/.claude*/settings.json "$HOME/.codex/hooks.json" | shasum)" = "$sum1" ] || { echo 'FAIL: second run changed files'; exit 1; }
[ "$(find "$HOME" -name '*.bak-grokbot-*' | wc -l | tr -d ' ')" = "$before" ] || { echo 'FAIL: second run made backups'; exit 1; }
# Invalid JSON is skipped, not clobbered.
printf '{ broken' > "$HOME/.claude-vmg/settings.json"
bash "$REPO/install.sh" >/dev/null 2>&1
[ "$(cat "$HOME/.claude-vmg/settings.json")" = '{ broken' ] || { echo 'FAIL: invalid JSON modified'; exit 1; }
echo '{}' > "$HOME/.claude-vmg/settings.json"; bash "$REPO/install.sh" >/dev/null 2>&1
# A custom list is honoured and a missing dir is skipped.
mkdir "$HOME/custom dir"
GROKBOT_CLAUDE_DIRS="$HOME/custom dir:$HOME/nope" bash "$REPO/install.sh" >/dev/null 2>&1
[ "$(cmds "$HOME/custom dir/settings.json" Notification | grep -c claude-notify)" = 1 ] || { echo 'FAIL: custom dir'; exit 1; }
[ ! -e "$HOME/nope" ] || { echo 'FAIL: created missing dir'; exit 1; }
# Uninstall removes ours everywhere and keeps the rest.
bash "$REPO/uninstall.sh" >/dev/null 2>&1
GROKBOT_CLAUDE_DIRS="$HOME/custom dir" bash "$REPO/uninstall.sh" >/dev/null 2>&1
grep -rl 'grokbot-hooks/notify.sh' "$HOME"/.claude*/settings.json "$HOME/custom dir/settings.json" "$HOME/.codex/hooks.json" 2>/dev/null | grep -v bak && { echo 'FAIL: hook left behind'; exit 1; }
[ "$(jq -r '.env.TOKEN' "$HOME/.claude/settings.json")" = sekret-value ] || { echo 'FAIL: uninstall dropped env'; exit 1; }
[ "$(cmds "$HOME/.claude/settings.json" Notification)" = 'echo other' ] || { echo 'FAIL: uninstall dropped other hook'; exit 1; }
printf 'PASS: installer merges Notification/Stop into all Claude config dirs, Codex PermissionRequest, no secrets printed, idempotent, invalid JSON skipped, uninstall\n'
