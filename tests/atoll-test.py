#!/usr/bin/env python3
"""Atoll-first delivery (docs/atoll.md) against a fake Atoll and a fake webhook on loopback.

Covers: off sends nothing to Atoll; shadow posts direct and a deliver:false copy; live success
posts nothing direct; error, timeout and no_route post direct and spool; a lost response gives a
duplicate with the same id; the spool replays with fallback_delivered; a refused event is not
spooled; the .atoll marker and .atoll-status win over the old names; no local path or key leaks.
"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
KEY = 'sk_test_fake_key_not_real'
atoll_events, direct, report = [], [], {}
mode = {'atoll': 'forward'}


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        assert self.headers['Authorization'] == 'Bearer ' + KEY
        self.reply(200, report)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/callback':
            direct.append(body)
            return self.reply(200, {})
        assert self.path == '/api/orgs/org-1/agent-events', self.path
        assert self.headers['Authorization'] == 'Bearer ' + KEY
        how = mode['atoll']
        atoll_events.append(body)
        if how == 'error':
            return self.reply(500, {})
        if how == 'refused':
            return self.reply(404, {'code': 'AGENT_ALIAS_NOT_FOUND'})
        if how == 'lost':
            # Recorded, but the answer never reaches the hook.
            time.sleep(5)
            return None
        forwarded = how == 'forward' and body['deliver']
        reason = 'forwarded' if forwarded else ('shadow' if not body['deliver'] else 'no_route')
        return self.reply(202, {'event_id': body['event_id'], 'forwarded': forwarded, 'reason': reason})

    def log_message(self, *_args):
        pass


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, *_args):
        pass


with tempfile.TemporaryDirectory(prefix='grokbot-atoll-') as temp:
    root = Path(temp).resolve()
    hooks, home, work = root / 'hooks', root / 'home', root / 'work'
    for folder in (hooks, home, work):
        folder.mkdir()
    for name in ('registry-lib.sh', 'config-lib.sh', 'atoll-lib.sh', 'atoll-shadow-compare.sh'):
        (hooks / name).write_text((REPO / 'hooks' / name).read_text())
    server = Server(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    (hooks / 'test.env').write_text(f'GROKBOT_WEBHOOK_URL={base}/callback\n')
    (hooks / 'atoll.key').write_text(KEY + '\n')
    env = dict(os.environ, HOME=str(home), GROKBOT_HOOKS_DIR=str(hooks), GROKBOT_STATE_DIR=str(root / 'state'),
               GROKBOT_T3_CLI='/nonexistent', GROKBOT_T3_DB_LOOKUP='0', GROKBOT_APPROVAL_MINUTES='0',
               NO_PROXY='127.0.0.1', no_proxy='127.0.0.1',
               GROKBOT_ATOLL_KEY_FILE=str(hooks / 'atoll.key'))
    for name in ('T3CODE_THREAD_ID', 'T3CODE_CLI_PATH', 'T3CODE_HOME'):
        env.pop(name, None)
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    log = hooks / 'notify.log'
    spool = hooks / 'atoll-spool'

    def config(**values):
        (hooks / 'config').write_text(''.join(f'{key}="{value}"\n' for key, value in values.items()))

    def flip(which):
        values = {'GROKBOT_ATOLL_URL': base, 'GROKBOT_ATOLL_ORG': 'org-1'}
        if which != 'off':
            values[f'GROKBOT_ATOLL_{which.upper()}_BOTS'] = 'other, test'
        config(**values)

    def completed():
        return log.read_text().count('worker-complete') if log.exists() else 0

    def turn(status, status_name='.atoll-status', harness='claude', session='session-1'):
        (work / status_name).write_text(status)
        before = completed()
        payload = {'cwd': str(work), 'session_id': session, 'last_assistant_message': 'Last words'}
        subprocess.run(['bash', str(REPO / 'hooks/notify.sh'), harness], input=json.dumps(payload),
                       text=True, env=env, cwd=root, check=True, capture_output=True)
        deadline = time.monotonic() + 30
        while completed() <= before:
            assert time.monotonic() < deadline, 'worker did not finish: ' + log.read_text()
            time.sleep(0.05)

    def spooled():
        return sorted(spool.glob('*.json')) if spool.exists() else []

    def reset():
        atoll_events.clear()
        direct.clear()

    (work / '.atoll').write_text(json.dumps({'agent': 'test', 'issue': 'AP-12'}))
    (work / '.grokbot').write_text('wrongbot\n')
    (work / '.grokbot-status').write_text('failed old name\n')

    # Off: direct only, unchanged body.
    flip('off')
    turn('done off https://github.com/o/r/pull/7')
    turn('waiting off')
    assert len(direct) == 1 and not atoll_events and 'atoll' not in direct[0], (direct, atoll_events)
    assert direct[0]['bot'] == 'test' and direct[0]['status'].startswith('done off'), direct[0]

    # Shadow: both, with the same id; Atoll gets no local path.
    reset()
    flip('shadow')
    turn('done shadow https://github.com/o/r/pull/7')
    assert len(direct) == 1 and len(atoll_events) == 1, (direct, atoll_events)
    event = atoll_events[0]
    assert event['deliver'] is False and direct[0]['atoll']['event_id'] == event['event_id']
    assert event['alias'] == 'test' and event['issue'] == 'AP-12' and event['harness'] == 'claude'
    assert event['thread']['id'] == 'session-1' and event['pr_url'] == 'https://github.com/o/r/pull/7'
    assert event['kind'] == 'turn_ended' and event['excerpt'] == 'Last words' and event['occurred_at'].endswith('Z')
    assert not {'worktree', 'cwd', 'transcript_path'} & set(event) and str(work) not in json.dumps(event)
    assert not spooled()
    first_seq = event['seq']

    # Live success: nothing direct, and the status counts as sent.
    reset()
    flip('live')
    turn('done live')
    assert len(atoll_events) == 1 and not direct and atoll_events[0]['deliver'] is True, (direct, atoll_events)
    assert atoll_events[0]['seq'] > first_seq
    # A repeated or waiting status is not sent to the bot, but Atoll still records it.
    turn('done live')
    turn('waiting for review')
    assert not direct and [(e['status'], e['deliver']) for e in atoll_events[1:]] == [
        ('done live', False), ('waiting for review', False)], (direct, atoll_events)

    # No route: direct, spooled, and replayed in the same run with fallback_delivered.
    reset()
    mode['atoll'] = 'no_route'
    turn('needs_input no route')
    assert len(direct) == 1 and len(atoll_events) == 2, (direct, atoll_events)
    assert atoll_events[1]['event_id'] == atoll_events[0]['event_id'] == direct[0]['atoll']['event_id']
    assert atoll_events[1]['fallback_delivered'] is True and not spooled()

    # Atoll down: direct and spooled; it replays when Atoll is back.
    reset()
    mode['atoll'] = 'error'
    turn('needs_input atoll down')
    assert len(direct) == 1 and len(spooled()) == 1, (direct, spooled())
    down_id = direct[0]['atoll']['event_id']
    reset()
    mode['atoll'] = 'forward'
    turn('waiting for CI')
    assert not direct
    replayed = [e for e in atoll_events if e['event_id'] == down_id]
    assert len(replayed) == 1 and replayed[0]['fallback_delivered'] is True and not spooled(), atoll_events

    # Lost response: the 4 s timeout gives a direct copy with the same id.
    reset()
    mode['atoll'] = 'lost'
    turn('needs_input lost')
    assert len(direct) == 1 and atoll_events[0]['event_id'] == direct[0]['atoll']['event_id']
    assert len(spooled()) == 1
    lost_id = atoll_events[0]['event_id']
    reset()
    mode['atoll'] = 'forward'
    turn('done after the loss')
    assert [e['event_id'] for e in atoll_events if e['fallback_delivered']] == [lost_id] and not spooled()

    # Refused for good: direct, and nothing to replay.
    reset()
    mode['atoll'] = 'refused'
    turn('failed unknown alias')
    assert len(direct) == 1 and len(atoll_events) == 1 and not spooled()

    # No thread identity: direct only.
    reset()
    mode['atoll'] = 'forward'
    turn('failed no identity', session='')
    assert len(direct) == 1 and not atoll_events

    # The old names still work on their own.
    reset()
    (work / '.atoll').unlink()
    (work / '.atoll-status').unlink()
    (work / '.grokbot').write_text('test\n')
    turn('done old names', status_name='.grokbot-status')
    assert atoll_events[0]['alias'] == 'test' and 'issue' not in atoll_events[0] and atoll_events[0]['status'] == 'done old names'

    # A .atoll folder keeps its marker inside.
    reset()
    (work / '.atoll').mkdir()
    (work / '.atoll/marker.json').write_text(json.dumps({'agent': 'test', 'issue': 'AP-13'}))
    turn('done folder marker')
    assert atoll_events[0]['issue'] == 'AP-13'

    # The comparison script reads the log and the report.
    seen = [e['event_id'] for e in atoll_events]
    shadow_id = next(line.split('event_id=')[1].split()[0] for line in log.read_text().splitlines() if 'mode=shadow' in line)
    report.update({'truncated': False, 'events': [
        {'event_id': shadow_id, 'status_word': 'done', 'would_forward': 'duplicate_status', 'latency_ms': 120},
        {'event_id': 'extra-1', 'status_word': 'failed', 'would_forward': 'forward', 'latency_ms': 300},
    ]})
    compared = subprocess.run(['bash', str(hooks / 'atoll-shadow-compare.sh'), 'test', '2000-01-01T00:00:00Z'],
                              env=env, capture_output=True, text=True, check=True).stdout
    assert 'direct pings Atoll would not forward: 1' in compared, compared
    assert 'Atoll would forward, no direct ping: 1' in compared and 'p95 hook to Atoll ms: 300' in compared, compared

    assert KEY not in log.read_text(), 'the key reached the log'
    assert not list(hooks.glob('.atoll-*')), 'temporary files left behind'
    server.shutdown()
print('atoll-test: ok')
