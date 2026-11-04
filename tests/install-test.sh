#!/bin/bash
# shellcheck disable=SC2015,SC2016 # the A && B || fail lines are checks, not if/else; single quotes keep $HOME literal
# Installer/uninstaller against a temporary HOME. Touches nothing outside it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset CLAUDE_CONFIG_DIR GROKBOT_CLAUDE_DIRS
mkdir -p "$HOME/.claude" "$HOME/.claude-work" "$HOME/.claude-extra" "$HOME/.codex"
# Existing keys (including a fake secret) and an unrelated hook must survive.
echo '{"env":{"TOKEN":"sekret-value"},"hooks":{"Notification":[{"hooks":[{"type":"command","command":"echo other"}]}]},"model":"x"}' > "$HOME/.claude/settings.json"
echo '{"env":{"TOKEN":"sekret-two"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/h/.grokbot-hooks/notify.sh claude"}]}]}}' > "$HOME/.claude-work/settings.json"
# ~/.claude-extra has no settings.json: not auto-detected, so the installer must leave it alone.
cmds() { jq -r --arg ev "$2" '.hooks[$ev][]?.hooks[]?.command' "$1"; }

OUT="$(bash "$REPO/install.sh" 2>&1)"
case "$OUT" in *sekret*) echo 'FAIL: installer printed a secret'; exit 1 ;; esac
for d in .claude .claude-work; do
  f="$HOME/$d/settings.json"
  [ "$(cmds "$f" Notification | grep -c 'grokbot-hooks/notify.sh claude-notify')" = 1 ] || { echo "FAIL: Notification missing in $d"; exit 1; }
  [ "$(cmds "$f" Stop | grep -c 'grokbot-hooks/notify.sh claude$')" = 1 ] || { echo "FAIL: Stop count in $d"; exit 1; }
done
[ ! -e "$HOME/.claude-extra/settings.json" ] || { echo 'FAIL: dir without settings.json picked up'; exit 1; }
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
printf '{ broken' > "$HOME/.claude-work/settings.json"
bash "$REPO/install.sh" >/dev/null 2>&1
[ "$(cat "$HOME/.claude-work/settings.json")" = '{ broken' ] || { echo 'FAIL: invalid JSON modified'; exit 1; }
echo '{}' > "$HOME/.claude-work/settings.json"; bash "$REPO/install.sh" >/dev/null 2>&1
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

# --- Auto-detect, override and config file, in a fresh HOME. ---
export HOME="$TMP/home2"
mkdir -p "$HOME/.codex" "$HOME/.claude-a b" "$HOME/.claude-nosettings" "$HOME/.claude-old.bak" \
  "$HOME/.claude-real" "$TMP/ext dir" "$TMP/override" "$TMP/envdir" "$TMP/cce"
echo '{}' > "$HOME/.claude-a b/settings.json"        # picked up, name has a space
echo '{}' > "$HOME/.claude-old.bak/settings.json"    # backup-looking name: skipped
echo '{}' > "$HOME/.claude-real/settings.json"
ln -s "$HOME/.claude-real" "$HOME/.claude-link"      # symlinked dir: skipped (it would repeat .claude-real)
echo '{}' > "$HOME/.claude-file"                      # a file, not a dir: skipped
has() { [ "$(cmds "$1/settings.json" Stop 2>/dev/null | grep -c 'grokbot-hooks/notify.sh claude$')" = 1 ]; }
hasnt() { [ ! -f "$1/settings.json" ] || ! grep -q 'grokbot-hooks/notify.sh' "$1/settings.json"; }
# No ~/.claude at all, CLAUDE_CONFIG_DIR is added.
CLAUDE_CONFIG_DIR="$TMP/cce" bash "$REPO/install.sh" >/dev/null 2>&1
has "$HOME/.claude-a b" || { echo 'FAIL: auto-detect missed dir with settings.json and a space'; exit 1; }
has "$HOME/.claude-real" || { echo 'FAIL: auto-detect missed real dir'; exit 1; }
has "$TMP/cce" || { echo 'FAIL: CLAUDE_CONFIG_DIR not used'; exit 1; }
hasnt "$HOME/.claude-nosettings" || { echo 'FAIL: dir without settings.json touched'; exit 1; }
hasnt "$HOME/.claude-old.bak" || { echo 'FAIL: backup dir touched'; exit 1; }
[ ! -e "$HOME/.claude" ] || { echo 'FAIL: created ~/.claude'; exit 1; }
[ "$(cmds "$HOME/.claude-real/settings.json" Stop | grep -c notify.sh)" = 1 ] || { echo 'FAIL: symlink dir double-installed'; exit 1; }
[ "$(cat "$HOME/.claude-file")" = '{}' ] || { echo 'FAIL: file touched'; exit 1; }
CLAUDE_CONFIG_DIR="$TMP/cce" bash "$REPO/uninstall.sh" >/dev/null 2>&1
hasnt "$HOME/.claude-a b" && hasnt "$HOME/.claude-real" && hasnt "$TMP/cce" || { echo 'FAIL: uninstall missed auto-detected dirs'; exit 1; }

# Config file: parsed, never run; extra dirs, override, precedence, never overwritten by install.sh.
CFG="$HOME/.grokbot-hooks/config"
cat > "$CFG" <<CONFIG
# comment
GROKBOT_STALL_MINUTES=7
BOGUS_KEY=ignored
touch "$TMP/ran-as-code"
GROKBOT_STATE_DIR=\$(touch "$TMP/ran-as-substitution")
export GROKBOT_EXTRA_CLAUDE_DIRS = "$TMP/ext dir:\$HOME/missing-extra"
CONFIG
printf '# my note\n' >> "$CFG"
sum_cfg="$(shasum < "$CFG")"
bash "$REPO/install.sh" >/dev/null 2>&1
[ "$(shasum < "$CFG")" = "$sum_cfg" ] || { echo 'FAIL: install.sh changed the config file'; exit 1; }
[ ! -e "$TMP/ran-as-code" ] && [ ! -e "$TMP/ran-as-substitution" ] || { echo 'FAIL: config file ran code'; exit 1; }
has "$TMP/ext dir" || { echo 'FAIL: GROKBOT_EXTRA_CLAUDE_DIRS from config not used'; exit 1; }
has "$HOME/.claude-a b" || { echo 'FAIL: extra replaced auto-detect'; exit 1; }
[ ! -e "$HOME/missing-extra" ] || { echo 'FAIL: created missing extra dir'; exit 1; }
bash "$REPO/uninstall.sh" >/dev/null 2>&1
hasnt "$TMP/ext dir" && hasnt "$HOME/.claude-a b" || { echo 'FAIL: uninstall ignored config'; exit 1; }
# GROKBOT_CLAUDE_DIRS in the config replaces auto-detect (with ~ and $HOME expanded) ...
mkdir -p "$HOME/only here"
printf '%s\n' 'GROKBOT_CLAUDE_DIRS=$HOME/only here:~/.claude-real' > "$CFG"
bash "$REPO/install.sh" >/dev/null 2>&1
has "$HOME/only here" && has "$HOME/.claude-real" || { echo 'FAIL: config GROKBOT_CLAUDE_DIRS not used'; exit 1; }
hasnt "$HOME/.claude-a b" || { echo 'FAIL: config override did not replace auto-detect'; exit 1; }
bash "$REPO/uninstall.sh" >/dev/null 2>&1
hasnt "$HOME/only here" && hasnt "$HOME/.claude-real" || { echo 'FAIL: uninstall ignored config override'; exit 1; }
# ... and a real environment variable beats the config file.
GROKBOT_CLAUDE_DIRS="$TMP/envdir" bash "$REPO/install.sh" >/dev/null 2>&1
has "$TMP/envdir" || { echo 'FAIL: env override not used'; exit 1; }
hasnt "$HOME/only here" && hasnt "$HOME/.claude-real" || { echo 'FAIL: config beat the environment'; exit 1; }
# A full override ignores GROKBOT_EXTRA_CLAUDE_DIRS from the config file.
printf 'GROKBOT_EXTRA_CLAUDE_DIRS=%s\n' "$TMP/ext dir" > "$CFG"
GROKBOT_CLAUDE_DIRS="$TMP/envdir" bash "$REPO/install.sh" >/dev/null 2>&1
hasnt "$TMP/ext dir" || { echo 'FAIL: extra dirs added to a full override'; exit 1; }
# The sourced parser itself: precedence, quoting, inline comments.
(
  . "$REPO/hooks/config-lib.sh"
  printf 'GROKBOT_STALL_MINUTES=12 # inline\nGROKBOT_STALE_SECONDS="300"\nGROKBOT_STATE_DIR='"'"'~/st ate'"'"'\n' > "$TMP/c"
  GROKBOT_STALE_SECONDS=99
  grokbot_load_config "$TMP/c"
  printf 'GROKBOT_CLAUDE_DIRS="~/only" # comment\nGROKBOT_STALL_MINUTES='"'"'3'"'"'   # c\nGROKBOT_STALE_SECONDS="x\n' > "$TMP/c2"
  unset GROKBOT_CLAUDE_DIRS GROKBOT_STALL_MINUTES GROKBOT_STALE_SECONDS
  grokbot_load_config "$TMP/c2"
  [ "$GROKBOT_CLAUDE_DIRS" = "$HOME/only" ] && [ "$GROKBOT_STALL_MINUTES" = 3 ] && [ -z "${GROKBOT_STALE_SECONDS:-}" ] || { echo "FAIL: quoted values ($GROKBOT_CLAUDE_DIRS $GROKBOT_STALL_MINUTES)"; exit 1; }
  unset GROKBOT_CLAUDE_DIRS GROKBOT_STALL_MINUTES GROKBOT_STATE_DIR
  GROKBOT_STALE_SECONDS=99
  grokbot_load_config "$TMP/c"
  [ "$GROKBOT_STALL_MINUTES" = 12 ] && [ "$GROKBOT_STALE_SECONDS" = 99 ] && [ "$GROKBOT_STATE_DIR" = "$HOME/st ate" ] || { echo "FAIL: parser ($GROKBOT_STALL_MINUTES $GROKBOT_STALE_SECONDS $GROKBOT_STATE_DIR)"; exit 1; }
) || exit 1
printf 'PASS: installer auto-detects Claude config dirs, honours GROKBOT_CLAUDE_DIRS and the config file (env > file), merges Notification/Stop into all Claude config dirs, Codex PermissionRequest, no secrets printed, idempotent, invalid JSON skipped, uninstall\n'
