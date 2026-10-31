#!/bin/bash
# Store one bot's webhook URL and Authorization header in ~/.grokbot-hooks/<bot>.env (mode 600).
# Usage: set-webhook.sh <bot-name>
# The header value is read with a hidden prompt so it never lands in shell history or the screen.
BOT="$(printf '%s' "$1" | tr -cd 'a-z0-9_-')"
[ -n "$BOT" ] || { echo "usage: $0 <bot-name>"; exit 1; }
mkdir -p "$HOME/.grokbot-hooks" && chmod 700 "$HOME/.grokbot-hooks"
read -r -p "Webhook URL for $BOT: " URL
read -r -s -p "Authorization header value (input hidden): " AUTH; echo
# Accept either "Bearer xyz" or a pasted "Authorization: Bearer xyz".
AUTH="${AUTH#Authorization: }"
umask 077
printf 'GROKBOT_WEBHOOK_URL=%q\nGROKBOT_WEBHOOK_AUTH=%q\n' "$URL" "$AUTH" > "$HOME/.grokbot-hooks/$BOT.env"
chmod 600 "$HOME/.grokbot-hooks/$BOT.env"
echo "Saved ~/.grokbot-hooks/$BOT.env"
