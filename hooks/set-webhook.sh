#!/bin/bash
# Store one bot's webhook in ~/.grokbot-hooks/<bot>.env (mode 600).
# Usage: set-webhook.sh <bot-name> [grokbot|openbot]
# Asks which kind of webhook it is unless you name it. Secrets are read with a hidden prompt, so they
# never land in shell history or on the screen.
#   grokbot  URL + Authorization header value (the original format)
#   openbot  URL + signing secret of an OpenBot webhook routine; notify.sh signs every request with it
BOT="$(printf '%s' "$1" | tr -cd 'a-z0-9_-')"
[ -n "$BOT" ] || { echo "usage: $0 <bot-name> [grokbot|openbot]"; exit 1; }
KIND="$2"
mkdir -p "$HOME/.grokbot-hooks" && chmod 700 "$HOME/.grokbot-hooks"
while :; do
  case "$KIND" in
    grokbot|openbot) break ;;
    '') ;;
    *) echo "Unknown webhook type '$KIND'." >&2 ;;
  esac
  read -r -p "Webhook type for $BOT (grokbot or openbot): " KIND || { echo >&2; exit 1; }
done
ENV_FILE="$HOME/.grokbot-hooks/$BOT.env"
read -r -p "Webhook URL for $BOT: " URL || exit 1
umask 077
if [ "$KIND" = openbot ]; then
  # Surrounding spaces from a paste would break the signature or the URL.
  URL="${URL#"${URL%%[![:space:]]*}"}"; URL="${URL%"${URL##*[![:space:]]}"}"
  case "$URL" in http://*|https://*) ;; *) echo "The URL must start with https:// (or http://)." >&2; exit 1 ;; esac
  read -r -s -p "Signing secret (input hidden): " SECRET || exit 1; echo
  SECRET="${SECRET#"${SECRET%%[![:space:]]*}"}"; SECRET="${SECRET%"${SECRET##*[![:space:]]}"}"
  [ -n "$SECRET" ] || { echo "The signing secret is empty; nothing saved." >&2; exit 1; }
  # printf is a shell builtin here, so the secret is not in any process argument.
  TMP="$(mktemp "$HOME/.grokbot-hooks/.$BOT.env.XXXXXX")" || exit 1
  printf 'GROKBOT_WEBHOOK_MODE=openbot\nGROKBOT_WEBHOOK_URL=%q\nGROKBOT_WEBHOOK_SECRET=%q\n' "$URL" "$SECRET" > "$TMP" \
    && chmod 600 "$TMP" && mv -f "$TMP" "$ENV_FILE" || { rm -f "$TMP"; echo "Could not write $ENV_FILE" >&2; exit 1; }
else
  read -r -s -p "Authorization header value (input hidden): " AUTH; echo
  # Accept either "Bearer xyz" or a pasted "Authorization: Bearer xyz".
  AUTH="${AUTH#Authorization: }"
  printf 'GROKBOT_WEBHOOK_URL=%q\nGROKBOT_WEBHOOK_AUTH=%q\n' "$URL" "$AUTH" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
echo "Saved ~/.grokbot-hooks/$BOT.env"
