#!/usr/bin/env python3
"""Spool boundary tests. Only temporary hook directories and generated placeholders are used."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='atoll-spool-test-') as temp:
    root = Path(temp)
    driver = root / 'driver.sh'
    driver.write_text('''#!/bin/bash
set -e
umask 077
DIR="$1"
JQ="$(command -v jq)"
BOT=test
. "$2/hooks/atoll-lib.sh"
atoll_spool "$(cat "$3")" "$4"
''')
    placeholder = uuid.uuid4().hex
    event = dict(event_id=str(uuid.uuid4()), kind='approval', alias='test', route='marker',
                 harness='codex', thread=dict(id=str(uuid.uuid4()), title=placeholder,
                                             parent_title=placeholder, host_id=placeholder),
                 occurred_at='2026-11-27T00:00:00.000Z', seq=123, deliver=True,
                 status='needs_input approval ' + placeholder, excerpt=placeholder,
                 branch=placeholder, pr_url=placeholder, issue=placeholder,
                 headers={'Authorization': placeholder}, error=placeholder,
                 debug={'env': {'EXAMPLE': placeholder}}, fallback_delivered=False)
    source = root / 'input.json'
    env = dict(os.environ, HOME=str(root), GROKBOT_ATOLL_KEY_FILE=str(root / 'atoll.key'))

    def spool(body, delivered=True):
        source.write_text(json.dumps(body))
        return subprocess.run(['bash', str(driver), str(root), str(REPO), str(source),
                               json.dumps(delivered)], env=env, capture_output=True)

    assert spool(event).returncode == 0
    spool_dir = root / 'atoll-spool'
    file = spool_dir / (event['event_id'] + '.json')
    saved = json.loads(file.read_text())
    assert set(saved) == {'event_id', 'kind', 'alias', 'route', 'harness', 'thread',
                          'occurred_at', 'seq', 'status', 'deliver', 'fallback_delivered'}
    assert saved['thread'] == {'id': event['thread']['id']}
    assert saved['status'] == 'needs_input' and saved['deliver'] is False
    assert saved['fallback_delivered'] is True
    assert all(placeholder not in entry.read_text() for entry in spool_dir.iterdir())
    assert file.stat().st_mode & 0o777 == 0o600

    # If neither path delivered, replay may still deliver; shadow/record-only must stay so.
    assert spool(event, False).returncode == 0
    assert json.loads(file.read_text())['deliver'] is True
    assert spool(dict(event, deliver=False), False).returncode == 0
    assert json.loads(file.read_text())['deliver'] is False
    assert spool(dict(event, status=placeholder)).returncode == 0
    assert json.loads(file.read_text())['status'] == 'turn_ended_no_status'

    # Invalid identifiers and arbitrary strings in closed-vocabulary fields are rejected
    # before a temporary spool file is opened. The previous valid entry is unchanged.
    before = {entry.name: entry.read_bytes() for entry in spool_dir.iterdir()}
    for changes in [dict(event_id='../escape'), dict(thread={'id': placeholder}),
                    dict(alias='Authorization: ' + placeholder), dict(kind=placeholder),
                    dict(route=placeholder), dict(harness=placeholder), dict(seq=placeholder),
                    dict(occurred_at=placeholder)]:
        result = spool(dict(event, **changes))
        assert result.returncode != 0, 'invalid spool input accepted'
        assert not result.stdout and not result.stderr, 'invalid input exposed diagnostics'
        assert before == {entry.name: entry.read_bytes() for entry in spool_dir.iterdir()}

    # Even UUID-shaped credentials must not be accepted as thread ids. Check API-key
    # files, exported values, and bot env values on the record-only path (no direct send).
    (root / 'atoll.key').write_text(event['thread']['id'])
    assert spool(event).returncode != 0
    (root / 'atoll.key').unlink()
    env['REVIEW_TEST_ENV_VALUE'] = event['thread']['id']
    assert spool(event).returncode != 0
    env.pop('REVIEW_TEST_ENV_VALUE')
    (root / 'test.env').write_text('GROKBOT_WEBHOOK_SECRET=' + event['thread']['id'] + '\n')
    assert spool(event).returncode != 0
    (root / 'test.env').write_text('GROKBOT_WEBHOOK_AUTH="Bearer ' + event['thread']['id'] + '"\n')
    assert spool(event).returncode != 0
    assert before == {entry.name: entry.read_bytes() for entry in spool_dir.iterdir()}

print('atoll-spool-test: ok')
