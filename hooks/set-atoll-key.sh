#!/bin/bash
# Store the machine integration key that notify.sh uses for Atoll. The key is read with a hidden
# prompt: it never appears on the screen, in shell history or in a process argument.
# macOS: the login Keychain. Linux (or --file): ~/.grokbot-hooks/atoll.key, mode 600.
DIR="${GROKBOT_HOOKS_DIR:-$HOME/.grokbot-hooks}"
mkdir -p "$DIR" && chmod 700 "$DIR" || exit 1
umask 077
if [ "${1:-}" != --file ] && command -v security >/dev/null 2>&1; then
  echo "Paste the Atoll integration key at both prompts (input hidden)."
  # -w as the last option makes security prompt for the value itself.
  security add-generic-password -U -s grokbot-atoll-key -a "$(id -un)" -w || { echo "Not saved." >&2; exit 1; }
  echo "Saved to the Keychain (service grokbot-atoll-key)."
  exit 0
fi
read -r -s -p "Atoll integration key (input hidden): " KEY || exit 1
echo
KEY="${KEY#"${KEY%%[![:space:]]*}"}"; KEY="${KEY%"${KEY##*[![:space:]]}"}"
case "$KEY" in ''|*[!A-Za-z0-9._-]*) echo "That does not look like a key; nothing saved." >&2; exit 1 ;; esac
TMP="$(mktemp "$DIR/.atoll.key.XXXXXX")" || exit 1
printf '%s\n' "$KEY" > "$TMP" && chmod 600 "$TMP" && mv -f "$TMP" "$DIR/atoll.key" || { rm -f "$TMP"; echo "Could not write the key file." >&2; exit 1; }
echo "Saved $DIR/atoll.key"
