# OpenBot "T3 callback" webhook routine

Use this when the bot runs on OpenBot instead of Grok Bot. The hook, the marker, the status words and the payload fields are the same. Only two things change: the request is signed, and the fields arrive inside a wrapper.

## Set it up

1. In OpenBot, create a **webhook routine** for the bot and name it "T3 callback". Use the prompt below as its prompt.
2. Copy the routine's **webhook URL** and its **signing secret**.
3. On the machine that runs T3 Code:

   ```bash
   ~/.grokbot-hooks/set-webhook.sh <bot-name>
   ```

   Answer `openbot`, paste the URL, then paste the signing secret. Both prompts hide your input. This writes `~/.grokbot-hooks/<bot-name>.env` (mode 600) with `GROKBOT_WEBHOOK_MODE=openbot`, `GROKBOT_WEBHOOK_URL` and `GROKBOT_WEBHOOK_SECRET`. The mode is always explicit: an env file with no `GROKBOT_WEBHOOK_MODE` is a Grok Bot webhook.
4. `python3` must be on the machine (`hooks/openbot-sign.py` signs the request). macOS has it.
5. Test: have the bot launch a small thread and watch `~/.grokbot-hooks/notify.log`. A delivered callback logs `webhook http=202 result=0 mode=openbot` (`http=200` means OpenBot had already received that event).

Never paste the URL or the signing secret into a chat, a brief or a prompt.

## What OpenBot receives

```json
{
  "type": "t3.callback",
  "occurredAt": "2026-11-25T08:15:00Z",
  "data": { "event": "t3_turn_ended", "bot": "...", "status": "...", "...": "..." }
}
```

`data` is the same object a Grok Bot routine gets as its whole body (see [Payload](../docs/hooks.md#payload)). Headers: `x-openbot-timestamp`, `x-openbot-delivery-id` and `x-openbot-signature` (`sha256=` and the hex HMAC-SHA256 of `<timestamp>.<delivery id>.<body>` with the signing secret). OpenBot checks them before it runs the routine. OpenBot answers 202 (accepted) or 200 (duplicate delivery id, already accepted); 401 means a wrong secret or a clock more than 5 minutes off, 404 a routine that is gone, 503 a host that is offline or busy (the hook retries once).

The whole body stays under 64 KB. If it would not, the hook shortens `last_message` first, then drops `my_open_threads`.

---

## Prompt

Paste this line at the top of the routine prompt, then the rest of [routine-prompt.md](routine-prompt.md) (or [cli-routine-prompt.md](cli-routine-prompt.md) for plain CLI sessions) unchanged:

```text
The webhook body is {"type":"t3.callback","occurredAt":...,"data":{...}}. Every field named below (event, bot, harness, worktree, branch, status, last_message, thread_id, ...) is inside `data`. Ignore the request if `type` is not "t3.callback".
```
