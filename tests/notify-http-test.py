#!/usr/bin/env python3
"""Exercise the real curl path using only a loopback server and temporary files."""
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
received = queue.Queue()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        received.put(body)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_args):
        pass


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='grokbot-http-') as temp:
    root = Path(temp).resolve()
    hooks = root / 'hooks'
    hooks.mkdir()
    home = root / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), GROKBOT_HOOKS_DIR=str(hooks),
               GROKBOT_STATE_DIR=str(root / 'state'), GROKBOT_STALE_SECONDS='0',
               NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (hooks / 'test.env').write_text(
        f'GROKBOT_WEBHOOK_URL=http://127.0.0.1:{server.server_port}/callback\n')
    completed = 0

    def invoke(harness, payload=None):
        global completed
        result = run('bash', str(REPO / 'hooks/notify.sh'), harness,
                     input=json.dumps(payload) if payload is not None else '',
                     env=env, cwd=root)
        assert result.stdout == '', result.stdout
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            log = hooks / 'notify.log'
            count = log.read_text().count('worker-complete') if log.exists() else 0
            if count > completed:
                completed = count
                return
            time.sleep(0.02)
        raise AssertionError('Detached worker did not finish')

    try:
        for index, (label, harness) in enumerate([
                ('t3-codex', 'codex'), ('t3-claude', 'claude'),
                ('plain-claude', 'claude'), ('plain-codex', 'codex')]):
            work = root / label
            work.mkdir()
            run('git', 'init', '-q', str(work))
            subdir = work / 'src'
            subdir.mkdir()
            (work / '.grokbot').write_text('test\n')
            (work / '.grokbot-status').write_text(f'done {label}\n')
            session = f'fake-session-{index}'
            transcript = str(root / 'history with spaces' / 'transcript.jsonl')
            payload = dict(cwd=str(subdir), session_id=session,
                           transcript_path=transcript if harness == 'claude' else None,
                           hook_event_name='Stop', stop_hook_active=False,
                           last_assistant_message=f'Finished {label}')
            invoke(harness, payload)
            body = received.get(timeout=1)
            assert body['event'] == 't3_turn_ended'
            assert body['harness'] == harness and body['bot'] == 'test'
            assert body['session_id'] == session
            assert body['transcript_path'] == (transcript if harness == 'claude' else '')
            assert body['cwd'] == str(subdir) and body['worktree'] == str(work)
            assert body['last_message'] == f'Finished {label}'
            assert body['status'] == f'done {label}\n'
            # New identity does not alter the existing status-only dedupe.
            invoke(harness, dict(payload, session_id='different-session'))
            assert received.empty()

        # Legacy T3 input remains valid; missing fields are empty.
        (work / '.grokbot-status').write_text('needs_input legacy')
        invoke('codex', dict(cwd=str(work)))
        body = received.get(timeout=1)
        assert body['session_id'] == body['transcript_path'] == ''
        assert body['cwd'] == str(work)
        invoke('codex', dict(cwd=str(work), session_id={}, transcript_path=42))
        body = received.get(timeout=1)
        assert body['session_id'] == body['transcript_path'] == ''

        # Sweeps must not inherit the identity of the current hook invocation.
        (work / '.grokbot-status').write_text('waiting external event')
        other = root / 'plain-claude'
        (other / '.grokbot-status').write_text('needs_input another task')
        invoke('claude', dict(cwd=str(other), session_id='other-session',
                             transcript_path='/fake/other.jsonl'))
        bodies = [received.get(timeout=1), received.get(timeout=1)]
        swept = next(body for body in bodies if body['harness'] == 'sweep')
        assert swept['worktree'] == str(work)
        assert swept['session_id'] == swept['transcript_path'] == swept['cwd'] == ''
        invoke('--sweep')
        swept = received.get(timeout=1)
        assert swept['harness'] == 'sweep'
        assert swept['session_id'] == swept['transcript_path'] == swept['cwd'] == ''
        assert received.empty()
        print('PASS: local HTTP, T3/Claude/Codex identity, legacy/null fields, dedupe, sweep isolation')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
