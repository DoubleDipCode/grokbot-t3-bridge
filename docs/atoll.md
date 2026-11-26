# Send hook events through Atoll

The hook can report every ping to [Atoll](https://atollhq.com), which links the
thread to its issue and forwards the callback to the bot's webhook. Direct posts
stay as the fallback. Without the settings below nothing changes.

## Modes, per bot

| Mode | Set | What happens |
| --- | --- | --- |
| off | nothing | Direct post, as before |
| shadow | `GROKBOT_ATOLL_SHADOW_BOTS` | Direct post as before, plus a copy to Atoll with `deliver: false` |
| live | `GROKBOT_ATOLL_LIVE_BOTS` | Atoll first (4 s timeout). Direct post and spool when Atoll fails, answers 5xx or answers `forwarded: false` |

Both lists take bot names separated by spaces or commas, or `*`. Live wins over
shadow. Put them in `~/.grokbot-hooks/config`:

```
GROKBOT_ATOLL_ORG=<organization id>
GROKBOT_ATOLL_SHADOW_BOTS="tidey"
# GROKBOT_ATOLL_URL=https://atollhq.com
```

A turn end that the bot is not pinged for (`waiting`, or the same status again)
is still sent to Atoll with `deliver: false`, so the execution state stays
current. The hook sends no `turn_started` event yet.

## Key

One machine integration key, allowed to report for the listed agents. Store it
with a hidden prompt:

```bash
~/.grokbot-hooks/set-atoll-key.sh
```

It goes to the macOS Keychain (service `grokbot-atoll-key`), or on Linux to
`~/.grokbot-hooks/atoll.key` (mode 600). The key is passed to curl on stdin and
is never logged. The aliases and the grant are set in Atoll
(`atoll agent-event alias set`, `atoll agent-event reporters set`).

## Marker and status files

New names: `.atoll` holds `{"agent":"<bot>","issue":"AP-123"}` (`issue` is
optional) and `.atoll-status` holds the status. `.grokbot` and `.grokbot-status`
are still read. When a repository already has a `.atoll/` folder for the Atoll
CLI, the marker is `.atoll/marker.json`. `atoll agent-event mark <bot> --issue AP-123`
writes the right file.

## What is sent

`event_id`, a per-thread `seq`, kind (`turn_ended`, `approval`, `sweep`), bot,
route, thread id and title, host name, parent and project ids, issue, branch,
status, PR link, the last message (1500 characters) and the time. No worktree,
working directory or transcript path. Atoll removes paths and key-shaped text
before it stores or forwards anything.

A ping with no thread id and no session id cannot be recorded, so it goes direct.

## Fallback and spool

In live mode a ping that Atoll did not forward is posted with the old env file.
The direct body then has `atoll.event_id`, the same id as an Atoll delivery of
that event, so the receiver can drop the repeat (a lost response gives both).

The event is also written to `~/.grokbot-hooks/atoll-spool/` when Atoll did not
answer, answered 408, 429 or 5xx, or answered `forwarded: false`. Later hook
runs and the sweep replay up to ten, oldest first, with `fallback_delivered`
set when the direct post worked. A refusal such as 400, 403 or 404 is not
spooled. Files older than seven days are deleted.

## Shadow comparison

```bash
~/.grokbot-hooks/atoll-shadow-compare.sh <bot> 2026-01-31T00:00:00Z
```

It reads `notify.log` and the Atoll report and lists direct pings that Atoll
misses or would not forward, forwards with no direct ping, and the p95 time from
the Stop hook to Atoll. The flip of a bot to live, and the rollback, are in
the Atoll repository: `docs/internal/agent-events-rollout.md`.

`notify.log` has one line per Atoll send:
`<time> <bot> atoll at=<epoch> mode=… event_id=… http=… reason=… direct=…`.
