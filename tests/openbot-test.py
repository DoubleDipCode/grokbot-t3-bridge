#!/usr/bin/env python3
"""OpenBot mode: signed webhook requests, over real HTTP on loopback with temporary files only.

Checks, with an HMAC computed independently of hooks/openbot-sign.py:
  - body shape {"type","occurredAt","data"}, headers, signature, timestamp window, delivery id format
  - 200 and 202 count as delivered, 401 does not; one retry on 503 and no more
  - Stop, approval and sweep pings all go through the signed sender; Grok Bot mode is unchanged
  - bad or missing mode/secret sends nothing
  - the secret, the URL and the signature never appear in process arguments, the child environment
    (curl, python3 are wrapped to record both) or notify.log
  - payload size limit, and set-webhook.sh output (mode 600, round trip)
"""
import datetime
import hashlib
import hmac
import http.server
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
SECRET = 'ZXQSECRET-k3y with "quote" \'single\' and \\ backslash + $dollar'
URL_TOKEN = 'ZXQURL-7f3a9c'
GROK_AUTH = 'Bearer ZXQGROKAUTH-55'
DELIVERY_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,255}')


class Request:
    def __init__(self, path, headers, raw):
        self.path, self.headers, self.raw = path, headers, raw


requests = queue.Queue()
statuses = queue.Queue()  # status codes to answer with, one per request; empty means 202


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        requests.put(Request(self.path, {k.lower(): v for k, v in self.headers.items()}, raw))
        try:
            code = statuses.get_nowait()
        except queue.Empty:
            code = 202
        self.send_response(code)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *_args):
        pass


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def expect_none(label):
    try:
        got = requests.get(timeout=0.4)
    except queue.Empty:
        return
    raise AssertionError(f'{label}: unexpected request to {got.path}')


def verify(req):
    """Check one OpenBot request against the contract; return its data object."""
    h = req.headers
    assert h['content-type'] == 'application/json', h
    assert 'authorization' not in h, 'OpenBot mode must not send the Grok Bot Authorization header'
    ts, delivery, signature = h['x-openbot-timestamp'], h['x-openbot-delivery-id'], h['x-openbot-signature']
    assert ts.isdigit() and abs(time.time() - int(ts)) < 300, ts
    assert DELIVERY_RE.fullmatch(delivery), delivery
    expected = 'sha256=' + hmac.new(SECRET.encode(), ts.encode() + b'.' + delivery.encode() + b'.' + req.raw,
                                    hashlib.sha256).hexdigest()
    assert hmac.compare_digest(signature, expected), 'signature does not match an independent HMAC'
    assert len(req.raw) <= 64 * 1024, len(req.raw)
    body = json.loads(req.raw)
    assert set(body) == {'type', 'occurredAt', 'data'}, sorted(body)
    assert body['type'] == 't3.callback'
    when = datetime.datetime.fromisoformat(body['occurredAt'].replace('Z', '+00:00'))
    assert when.tzinfo is not None and abs(time.time() - when.timestamp()) < 300, body['occurredAt']
    assert isinstance(body['data'], dict)
    return body['data']


def load_signer():
    spec = importlib.util.spec_from_file_location('openbot_sign', REPO / 'hooks/openbot-sign.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unit_tests():
    signer = load_signer()
    now = 1_800_000_000
    # The signature in the config is the HMAC of "<timestamp>.<delivery id>.<exact body bytes>".
    cfg = signer.make_config('k', 'https://example.test/x', json.dumps({'status': 'done', 'last_message': 'é"\\'}), now=now)
    lines = dict(line.split(' = ', 1) for line in cfg.splitlines())
    ts = re.search(r'x-openbot-timestamp: (\d+)', cfg).group(1)
    did = re.search(r'x-openbot-delivery-id: ([^"]+)"', cfg).group(1)
    sig = re.search(r'x-openbot-signature: (sha256=[0-9a-f]{64})"', cfg).group(1)
    assert ts == str(now) and DELIVERY_RE.fullmatch(did)
    body = json.loads(lines['data-binary']).encode()  # a curl config string (only \\ and \" escaped) is a JSON string
    assert sig == 'sha256=' + hmac.new(b'k', f'{ts}.{did}.'.encode() + body, hashlib.sha256).hexdigest()
    assert json.loads(body) == {'type': 't3.callback', 'occurredAt': '2027-01-15T08:00:00Z',
                                'data': {'status': 'done', 'last_message': 'é"\\'}}
    # Two events never share a delivery id, even within one second.
    assert signer.delivery_id(now) != signer.delivery_id(now)
    # Big payloads are trimmed to the limit and stay valid, signed JSON.
    for text in ['x' * 300_000, 'é' * 100_000, '\U0001f600' * 40_000, 'line\n"q"\\' * 30_000]:
        data = {'status': 'done', 'last_message': text, 'my_open_threads': ['a|b|c|d'] * 3, 'my_open_threads_more': 0}
        body, trimmed = signer.fit(data, '2027-01-15T08:00:00Z')
        assert len(body) <= 64000, len(body)
        assert json.loads(body)['data']['last_message'].endswith('[truncated]')
        assert trimmed['status'] == 'done'
    # last_message trimming alone is enough, so the open threads survive.
    body, trimmed = signer.fit({'last_message': 'x' * 100_000, 'my_open_threads': ['t'], 'my_open_threads_more': 0},
                               '2027-01-15T08:00:00Z')
    assert trimmed['my_open_threads'] == ['t']
    # A small payload is untouched.
    body, trimmed = signer.fit({'last_message': 'short'}, '2027-01-15T08:00:00Z')
    assert trimmed['last_message'] == 'short'
    # A payload that cannot shrink below the limit is refused, never sent oversized.
    huge = {'status': 'x', **{f'k{i}': 'y' * 900 for i in range(120)}}
    try:
        signer.fit(huge, '2027-01-15T08:00:00Z')
        raise AssertionError('oversized payload was accepted')
    except signer.SignError as error:
        assert error.code == 3
    # Bad input.
    for secret, url, payload in [('', 'https://x', '{}'), ('k', 'ftp://x', '{}'), ('k', 'https://x', '[]'),
                                 ('k', 'https://x', 'nope'), ('k', 'https://x/\nheader = "evil"', '{}')]:
        try:
            signer.make_config(secret, url, payload, now=now)
            raise AssertionError(f'accepted {secret!r} {url!r} {payload!r}')
        except signer.SignError as error:
            assert error.code == 2


def main():
    unit_tests()
    real_curl = shutil.which('curl')
    real_python = os.path.realpath(sys.executable)
    with tempfile.TemporaryDirectory(prefix='openbot-test-') as temp:
        root = Path(temp).resolve()
        hooks, home, shim, rec = root / 'hooks', root / 'home', root / 'shim', root / 'rec'
        for d in (hooks, home, shim, rec):
            d.mkdir()
        shutil.copy(REPO / 'hooks/registry-lib.sh', hooks)
        shutil.copy(REPO / 'hooks/openbot-sign.py', hooks)
        # Wrap curl and python3: record every argument and the whole environment, then run the real one.
        for name, real in (('curl', real_curl), ('python3', real_python)):
            wrapper = shim / name
            wrapper.write_text(
                '#!/bin/bash\n'
                f'printf "%s\\0" "$@" >> {shlex.quote(str(rec / (name + ".argv")))}\n'
                f'env >> {shlex.quote(str(rec / (name + ".env")))}\n'
                f'exec {shlex.quote(real)} "$@"\n')
            wrapper.chmod(0o755)
        env = dict(os.environ, HOME=str(home), GROKBOT_HOOKS_DIR=str(hooks),
                   GROKBOT_STATE_DIR=str(root / 'state'), GROKBOT_STALE_SECONDS='7200',
                   NO_PROXY='127.0.0.1', no_proxy='127.0.0.1', PATH=f'{shim}:{os.environ["PATH"]}',
                   GROKBOT_T3_CLI='/nonexistent', GROKBOT_T3_DB_LOOKUP='0')
        for key in ('T3CODE_THREAD_ID', 'T3CODE_CLI_PATH', 'T3CODE_HOME', 'GROKBOT_WEBHOOK_SECRET'):
            env.pop(key, None)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}/hooks/{URL_TOKEN}'
        log = hooks / 'notify.log'
        completed = 0

        def write_env(bot, **fields):
            lines = ''.join(f'{key}={shlex.quote(value)}\n' for key, value in fields.items())
            (hooks / f'{bot}.env').write_text(lines)

        def invoke(harness, payload=None, extra=None):
            nonlocal completed
            run_env = dict(env, **(extra or {}))
            result = run('bash', str(REPO / 'hooks/notify.sh'), harness,
                         input=json.dumps(payload) if payload is not None else '', env=run_env, cwd=root)
            assert result.stdout == '', result.stdout
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                count = log.read_text().count('worker-complete') if log.exists() else 0
                if count > completed:
                    completed = count
                    return
                time.sleep(0.02)
            raise AssertionError('Detached worker did not finish')

        def worktree(name, bot, status):
            work = root / name
            work.mkdir()
            run('git', 'init', '-q', str(work))
            (work / '.grokbot').write_text(bot + '\n')
            (work / '.grokbot-status').write_text(status)
            return work

        def stop(work, message='Finished'):
            invoke('claude', dict(cwd=str(work), session_id='s1', hook_event_name='Stop',
                                  last_assistant_message=message))

        try:
            write_env('ob', GROKBOT_WEBHOOK_MODE='openbot', GROKBOT_WEBHOOK_URL=base, GROKBOT_WEBHOOK_SECRET=SECRET)
            write_env('legacy', GROKBOT_WEBHOOK_URL=base + '/legacy', GROKBOT_WEBHOOK_AUTH=GROK_AUTH)
            ob = worktree('ob-work', 'ob', 'done first task')
            legacy = worktree('legacy-work', 'legacy', 'done legacy task')

            # 1. A Stop ping: signed, wrapped, and the whole existing payload sits under "data".
            stop(ob, 'Finished the ZXQ task')
            req = requests.get(timeout=2)
            assert req.path == f'/hooks/{URL_TOKEN}'
            data = verify(req)
            assert data['event'] == 't3_turn_ended' and data['bot'] == 'ob' and data['harness'] == 'claude'
            assert data['status'] == 'done first task' and data['last_message'] == 'Finished the ZXQ task'
            assert data['worktree'] == str(ob) and data['session_id'] == 's1'
            assert {'branch', 'ended_at', 'cwd', 'thread_id', 'route', 'my_open_threads'} <= set(data)
            first_delivery = req.headers['x-openbot-delivery-id']
            expect_none('first stop')

            # 2. 200 (duplicate) counts as delivered, so the same status is not sent again; 401 does not.
            statuses.put(200)
            (ob / '.grokbot-status').write_text('done second task')
            stop(ob)
            verify(requests.get(timeout=2))
            stop(ob)
            expect_none('duplicate after 200')
            statuses.put(401)
            (ob / '.grokbot-status').write_text('done third task')
            stop(ob)
            verify(requests.get(timeout=2))
            stop(ob)  # not recorded after a 401, so it is tried again
            req = requests.get(timeout=2)
            assert verify(req)['status'] == 'done third task'
            assert req.headers['x-openbot-delivery-id'] != first_delivery
            assert 'http=401' in log.read_text()

            # 3. 503: exactly one quick retry, same delivery id and body; a 202 on the retry is a success.
            (ob / '.grokbot-status').write_text('done fourth task')
            statuses.put(503)
            statuses.put(202)
            stop(ob)
            a, b = requests.get(timeout=2), requests.get(timeout=3)
            verify(a), verify(b)
            assert a.headers['x-openbot-delivery-id'] == b.headers['x-openbot-delivery-id'] and a.raw == b.raw
            expect_none('after 503 then 202')
            stop(ob)
            expect_none('recorded after the retry succeeded')
            # Two 503s: still only one retry, and the failure is not recorded.
            (ob / '.grokbot-status').write_text('done fifth task')
            statuses.put(503)
            statuses.put(503)
            stop(ob)
            verify(requests.get(timeout=2)), verify(requests.get(timeout=3))
            expect_none('no third attempt')
            stop(ob)  # not recorded, so a later turn sends it again
            assert verify(requests.get(timeout=2))['status'] == 'done fifth task'

            # 4. Approval pings use the same signed sender, every time.
            for _ in range(2):
                invoke('claude-notify', dict(cwd=str(ob), hook_event_name='Notification',
                                             notification_type='permission_prompt',
                                             message='Claude needs your permission to use Bash'))
                data = verify(requests.get(timeout=2))
                assert data['status'] == 'needs_input approval Claude needs your permission to use Bash'
                assert data['harness'] == 'claude-notify' and data['bot'] == 'ob'
            invoke('codex-permission', dict(cwd=str(ob), hook_event_name='PermissionRequest',
                                            tool_name='Bash', tool_input=dict(command='ls -la')))
            assert verify(requests.get(timeout=2))['status'] == 'needs_input approval Bash: ls -la'

            # 5. The sweep: a waiting status past GROKBOT_STALE_SECONDS is re-sent as "stale ...".
            (ob / '.grokbot-status').write_text('waiting for CI')
            stop(ob)
            expect_none('waiting is not sent at turn end')
            invoke('--sweep', extra={'GROKBOT_STALE_SECONDS': '0'})
            data = verify(requests.get(timeout=2))
            assert data['harness'] == 'sweep' and data['status'] == 'stale waiting for CI', data
            expect_none('sweep sent once')

            # 7. Misconfigured bots send nothing: openbot without a secret, and a mode that is not exact.
            write_env('ob', GROKBOT_WEBHOOK_MODE='openbot', GROKBOT_WEBHOOK_URL=base)
            (ob / '.grokbot-status').write_text('done no secret')
            stop(ob)
            expect_none('openbot without a secret')
            assert 'openbot-no-secret' in log.read_text()
            write_env('ob', GROKBOT_WEBHOOK_MODE='OpenBot', GROKBOT_WEBHOOK_URL=base, GROKBOT_WEBHOOK_SECRET=SECRET)
            stop(ob)
            expect_none('unknown mode')
            assert 'unknown-mode' in log.read_text()
            # A secret in an env file that exports it is still not passed on to children.
            (hooks / 'ob.env').write_text(
                f'export GROKBOT_WEBHOOK_MODE=openbot\nexport GROKBOT_WEBHOOK_URL={shlex.quote(base)}\n'
                f'export GROKBOT_WEBHOOK_SECRET={shlex.quote(SECRET)}\n')
            (ob / '.grokbot-status').write_text('done exported secret')
            stop(ob)
            assert verify(requests.get(timeout=2))['status'] == 'done exported secret'

            # 8. The secret, the URL and every signature stay out of arguments, environments and the log.
            argv = (rec / 'curl.argv').read_bytes() + (rec / 'python3.argv').read_bytes()
            environment = (rec / 'curl.env').read_bytes() + (rec / 'python3.env').read_bytes()
            assert argv and environment, 'the curl and python3 wrappers did not run'
            logged = log.read_bytes()
            for what, blob in (('process arguments', argv), ('child environment', environment), ('notify.log', logged)):
                for secret_part in (SECRET, 'ZXQSECRET', URL_TOKEN, '127.0.0.1:%d' % server.server_port):
                    assert secret_part.encode() not in blob, f'{secret_part!r} leaked into {what}'
                assert b'x-openbot-signature' not in blob and b'sha256=' not in blob, f'signature leaked into {what}'
                assert b'x-openbot-timestamp' not in blob, f'headers leaked into {what}'

            # 8b. Grok Bot mode is unchanged (after the leak check: its URL and header are in curl's arguments, as before): bare payload, Authorization header, no OpenBot headers.
            stop(legacy, 'legacy message')
            req = requests.get(timeout=2)
            assert req.path == f'/hooks/{URL_TOKEN}/legacy'
            assert req.headers['authorization'] == GROK_AUTH
            assert not [h for h in req.headers if h.startswith('x-openbot')]
            body = json.loads(req.raw)
            assert body['event'] == 't3_turn_ended' and body['bot'] == 'legacy' and body['last_message'] == 'legacy message'
            assert 'data' not in body and 'type' not in body

            # 9. set-webhook.sh.
            set_env = dict(os.environ, HOME=str(root / 'sethome'))
            (root / 'sethome').mkdir()
            script = str(REPO / 'hooks/set-webhook.sh')
            written = root / 'sethome/.grokbot-hooks/newbot.env'
            # Unknown answer is asked again; spaces around the pasted URL and secret are trimmed.
            result = subprocess.run(['bash', script, 'newbot'], env=set_env, capture_output=True, text=True,
                                    input=f'nope\nopenbot\n  https://openbot.test/h/{URL_TOKEN}  \n  {SECRET}  \n')
            assert result.returncode == 0, result.stderr
            assert SECRET not in result.stdout + result.stderr
            assert stat.S_IMODE(written.stat().st_mode) == 0o600
            assert stat.S_IMODE(written.parent.stat().st_mode) == 0o700
            dumped = run('bash', '-c', '. "$1"; printf "%s\\n%s\\n%s" "$GROKBOT_WEBHOOK_MODE" "$GROKBOT_WEBHOOK_URL" "$GROKBOT_WEBHOOK_SECRET"',
                         'x', str(written)).stdout
            assert dumped == f'openbot\nhttps://openbot.test/h/{URL_TOKEN}\n{SECRET}', dumped
            assert 'GROKBOT_WEBHOOK_AUTH' not in written.read_text()
            assert not list(written.parent.glob('.newbot.env.*')), 'temp file left behind'
            # Mode on the command line; an empty secret or a bad URL saves nothing.
            written.unlink()
            for answers in ('https://openbot.test/h\n\n', 'ftp://x\nsecret\n'):
                result = subprocess.run(['bash', script, 'newbot', 'openbot'], env=set_env, capture_output=True,
                                        text=True, input=answers)
                assert result.returncode != 0 and not written.exists(), answers
            # Grok Bot answer: the original two-line format, no mode line.
            result = subprocess.run(['bash', script, 'newbot', 'grokbot'], env=set_env, capture_output=True, text=True,
                                    input='https://grok.test/h\nAuthorization: Bearer tok\n')
            assert result.returncode == 0, result.stderr
            assert stat.S_IMODE(written.stat().st_mode) == 0o600
            assert written.read_text() == 'GROKBOT_WEBHOOK_URL=https://grok.test/h\nGROKBOT_WEBHOOK_AUTH=Bearer\\ tok\n', written.read_text()
            # On a real terminal neither the OpenBot URL nor the secret is echoed (the pipe tests above
            # cannot see echo, so use a pty); the Grok Bot URL prompt stays visible, as before.
            import pty, select
            def on_terminal(answers, *args):
                master, slave = pty.openpty()
                proc = subprocess.Popen(['bash', script, 'ttybot', *args], env=set_env, stdin=slave,
                                        stdout=slave, stderr=slave, close_fds=True)
                os.close(slave)
                shown = b''
                for answer in answers:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline and select.select([master], [], [], 0.1)[0]:
                        shown += os.read(master, 4096)
                    os.write(master, answer.encode() + b'\n')
                proc.wait(timeout=10)
                while select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    shown += chunk
                os.close(master)
                return proc.returncode, shown
            code, shown = on_terminal(['https://tty.test/ZXQTTYURL', 'ZXQTTYSECRET'], 'openbot')
            assert code == 0, shown
            assert b'ZXQTTYURL' not in shown and b'ZXQTTYSECRET' not in shown, shown
            assert 'ZXQTTYURL' in (root / 'sethome/.grokbot-hooks/ttybot.env').read_text()
            code, shown = on_terminal(['https://tty.test/visible', 'Bearer ZXQTTYAUTH'], 'grokbot')
            assert code == 0 and b'tty.test/visible' in shown and b'ZXQTTYAUTH' not in shown, shown
            # Closed input ends the question loop instead of spinning.
            result = subprocess.run(['bash', script, 'newbot'], env=set_env, capture_output=True, text=True,
                                    input='', timeout=10)
            assert result.returncode != 0
            print('PASS: OpenBot signing (independent HMAC), body/headers, 200/202/401/503 handling, '
                  'stop/approval/sweep pings, Grok Bot mode unchanged, bad config, no secret leaks, '
                  'size limit, set-webhook')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
