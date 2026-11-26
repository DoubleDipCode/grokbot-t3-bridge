#!/usr/bin/env python3
"""Sign one OpenBot webhook request for notify.sh.

Reads from stdin (never from argv or the environment, so nothing secret shows up in `ps`):
  line 1  the signing secret
  line 2  the webhook URL
  rest    the payload JSON object (what Grok Bot mode would POST as the whole body)

Writes to stdout a curl config (for `curl -K -`) that sends the signed request. The config holds
the URL, the headers (with the signature, not the secret) and the body, so the secret, the URL and
the signature never go on a command line. Nothing is written to stderr.

Request contract (OpenBot webhook routine):
  body       {"type": "t3.callback", "occurredAt": "<ISO 8601>", "data": <payload>}, at most 64 KB
  headers    x-openbot-timestamp    Unix seconds
             x-openbot-delivery-id  unique per event
             x-openbot-signature    sha256=<hex HMAC-SHA256 of "<timestamp>.<delivery id>.<body bytes>">

Exit codes: 0 ok, 2 bad input (secret, URL, payload), 3 payload cannot be made small enough.
"""
import datetime
import hashlib
import hmac
import json
import sys
import time
import uuid

# OpenBot accepts 64 KB. Stay under 64000 bytes so a decimal or a binary reading of "KB" both fit.
MAX_BODY_BYTES = 64000
EVENT_TYPE = "t3.callback"
TRUNCATED = "\n[truncated]"
FIELD_CAP = 1000  # last resort: cap every string field to this many characters


class SignError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def build_body(data, occurred_at):
    """Compact, ASCII-only JSON, so the bytes signed are exactly the bytes sent."""
    return json.dumps(
        {"type": EVENT_TYPE, "occurredAt": occurred_at, "data": data},
        ensure_ascii=True, separators=(",", ":")).encode("ascii")


def fit(data, occurred_at, limit=MAX_BODY_BYTES):
    """Return (body bytes, data) with len(body) <= limit, trimming the payload only if it must.

    Order: shorten last_message, then drop my_open_threads, then cap every long string field.
    Raises SignError(3) when even that is too big.
    """
    data = dict(data)
    body = build_body(data, occurred_at)
    # 1. last_message: the free text and the usual cause of an oversized payload. Every character
    #    takes at least one byte in the body, so cutting `over` characters always frees `over` bytes.
    base = data.get("last_message")
    if len(body) > limit and isinstance(base, str):
        keep = len(base)
        marker = len(TRUNCATED)  # the marker costs bytes the first time it is added
        while len(body) > limit and keep > 0:
            keep = max(0, keep - (len(body) - limit) - marker)
            marker = 0
            data["last_message"] = base[:keep] + TRUNCATED
            body = build_body(data, occurred_at)
    # 2. The list of the bot's other open threads.
    if len(body) > limit and isinstance(data.get("my_open_threads"), list):
        data["my_open_threads_more"] = (data.get("my_open_threads_more") or 0) + len(data["my_open_threads"])
        data["my_open_threads"] = []
        body = build_body(data, occurred_at)
    # 3. Any other long string.
    if len(body) > limit:
        for key, value in list(data.items()):
            if isinstance(value, str) and len(value) > FIELD_CAP:
                data[key] = value[:FIELD_CAP] + TRUNCATED
        body = build_body(data, occurred_at)
    if len(body) > limit:
        raise SignError(3)
    return body, data


def delivery_id(now):
    """Unique per call: letters, digits and '-' only, well under 256 characters."""
    return "t3-%d-%s" % (now, uuid.uuid4().hex)


def sign(secret, timestamp, delivery, body):
    message = ("%s.%s." % (timestamp, delivery)).encode("ascii") + body
    return "sha256=" + hmac.new(secret.encode("utf-8"), message, hashlib.sha256).hexdigest()


def quote(value):
    """A curl config string. Only backslash and double quote need escaping; control characters
    (which could start another config line) are refused."""
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        raise SignError(2)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def make_config(secret, url, payload_text, now=None):
    """The curl config text for one signed POST. Pure function: no I/O."""
    if not secret or not url.startswith(("http://", "https://")):
        raise SignError(2)
    try:
        data = json.loads(payload_text)
    except ValueError:
        raise SignError(2)
    if not isinstance(data, dict):
        raise SignError(2)
    now = int(time.time()) if now is None else now
    occurred_at = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body, _ = fit(data, occurred_at)
    timestamp = str(now)
    delivery = delivery_id(now)
    signature = sign(secret, timestamp, delivery, body)
    lines = [
        "url = " + quote(url),
        'request = "POST"',
        'header = "Content-Type: application/json"',
        "header = " + quote("x-openbot-timestamp: " + timestamp),
        "header = " + quote("x-openbot-delivery-id: " + delivery),
        "header = " + quote("x-openbot-signature: " + signature),
        "data-binary = " + quote(body.decode("ascii")),
        'output = "/dev/null"',
        'write-out = "%{http_code}"',
    ]
    return "\n".join(lines) + "\n"


def main():
    try:
        raw = sys.stdin.buffer.read()
        first, sep1, rest = raw.partition(b"\n")
        second, sep2, payload = rest.partition(b"\n")
        if not (sep1 and sep2):
            raise SignError(2)
        secret = first.decode("utf-8").rstrip("\r")
        url = second.decode("utf-8").rstrip("\r")
        sys.stdout.write(make_config(secret, url, payload.decode("utf-8")))
        sys.stdout.flush()
        return 0
    except SignError as error:
        return error.code
    except Exception:  # never print a traceback: it could carry request data
        return 2


if __name__ == "__main__":
    sys.exit(main())
