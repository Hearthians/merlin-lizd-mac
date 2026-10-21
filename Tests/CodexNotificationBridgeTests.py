#!/usr/bin/env python3
"""Exercise the exact embedded helper in an isolated temporary directory.

Does not change HOME, CODEX_HOME, real hook files, tmux sessions or SSH hosts.
"""
import base64
import concurrent.futures
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import time
import uuid
from types import SimpleNamespace


def main():
    source_file = Path(__file__).resolve().parents[1] / 'Sources/TmuxHubCore/CodexNotificationBridge.swift'
    match = re.search(r'static let helperSource = #"""\n(.*?)\n    """#', source_file.read_text(), re.S)
    assert match, 'embedded helper not found'
    source = textwrap.dedent(match.group(1)) + '\n'
    compile(source, 'bridge.py', 'exec')
    with tempfile.TemporaryDirectory(prefix='tmuxhub-codex-notification-test-') as temporary:
        root = Path(temporary) / 'feed'
        root.mkdir()
        helper = root / 'bridge.py'
        codex_directory = Path(temporary) / 'codex'
        codex_directory.mkdir()
        hooks = codex_directory / 'hooks.json'
        original = {'description': 'keep this', 'hooks': {
            'Stop': [{'hooks': [{'type': 'command', 'command': 'printf existing'}]}],
            'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'true'}]}],
        }}
        hooks.write_text(json.dumps(original))
        scope = {'__name__': 'isolated_bridge', '__file__': str(helper)}
        exec(compile(source, str(helper), 'exec'), scope)
        scope['shutil'].which = lambda _: None
        receipt = scope['install'](source.encode(), str(codex_directory))
        first_contents = hooks.read_bytes()
        first_state = json.loads((root / 'state.json').read_text())
        assert receipt['sourceID'] == first_state['sourceID']
        assert '/hooks' in receipt['message']
        scope['install'](source.encode(), str(codex_directory))
        assert hooks.read_bytes() == first_contents, 'second installation changed hooks'
        assert json.loads((root / 'state.json').read_text()) == first_state
        merged = json.loads(first_contents)
        assert merged['description'] == original['description']
        assert merged['hooks']['PreToolUse'] == original['hooks']['PreToolUse']
        assert merged['hooks']['Stop'][0] == original['hooks']['Stop'][0]
        assert len(merged['hooks']['Stop']) == 2
        for name in ('Stop', 'PermissionRequest', 'UserPromptSubmit'):
            own = merged['hooks'][name][-1]['hooks'][0]
            assert own['type'] == 'command' and own['timeout'] == 3
            assert 'bypass' not in own['command']
        assert len(list(codex_directory.glob('hooks.json.tmuxhub-backup-*'))) == 1
        real_run = scope['subprocess'].run
        try:
            scope['shutil'].which = lambda _: '/test/codex'
            scope['subprocess'].run = lambda *args, **kwargs: SimpleNamespace(stdout=b'hooks stable false\n')
            disabled = scope['install'](source.encode(), str(codex_directory))
            assert 'codex features enable hooks' in disabled['message']
            assert '/hooks' in disabled['message']
        finally:
            scope['subprocess'].run = real_run
            scope['shutil'].which = lambda _: None

        environment = {key: value for key, value in os.environ.items() if key not in ('TMUX', 'TMUX_PANE')}
        def send(index, event='Stop'):
            payload = {'hook_event_name': event, 'session_id': 'session-1', 'turn_id': f'turn-{index}',
                       'cwd': 'relative/path' if index == 0 else '/work/project', 'prompt': 'secret prompt',
                       'tool_input': {'command': 'secret tool'}, 'last_assistant_message': 'secret answer'}
            result = subprocess.run([sys.executable, str(helper), 'emit'], input=json.dumps(payload).encode(),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=8)
            assert result.returncode == 0 and result.stdout.strip() == b'{}', result.stderr
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(send, range(32)))
        send(33, 'PermissionRequest')
        send(34, 'UserPromptSubmit')
        first = scope['read_feed'](0, 10)
        assert first == scope['read_feed'](0, 10), 'one device consumed another device events'
        assert first['hasMore'] and first['latestSequence'] == 34
        seen = list(first['events'])
        cursor = seen[-1]['sequence']
        while True:
            page = scope['read_feed'](cursor, 10)
            seen.extend(page['events'])
            if not page['hasMore']:
                break
            cursor = page['events'][-1]['sequence']
        assert len(seen) == 34
        assert [event['sequence'] for event in seen] == list(range(1, 35))
        assert len({event['id'] for event in seen}) == 34
        assert seen[-2]['kind'] == 'approvalRequested' and seen[-1]['kind'] == 'turnStarted'
        assert all(event['sourceID'] == first_state['sourceID'] for event in seen)
        assert all('secret' not in json.dumps(event) for event in seen)
        assert next(event for event in seen if event['turnID'] == 'turn-0')['cwd'] == ''
        assert len(list((root / 'events').glob('*.json'))) == 34, 'reading deleted events'
        invalid = subprocess.run([sys.executable, str(helper), 'emit'], input=b'{bad',
                                 stdout=subprocess.PIPE, env=environment, timeout=5)
        assert invalid.returncode == 0 and invalid.stdout.strip() == b'{}'
        assert scope['read_feed'](0, 100)['latestSequence'] == 34

        # Explicit reads are shared, while delivery cursors remain independent.
        def acknowledge(ids, source_id=first_state['sourceID'], succeeds=True):
            request = base64.b64encode(json.dumps({'sourceID': source_id, 'eventIDs': ids}).encode()).decode()
            result = subprocess.run([sys.executable, str(helper), 'ack', request],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=8)
            if succeeds:
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == {'sourceID': source_id, 'acknowledged': True}
            else:
                assert result.returncode != 0
        acknowledge([seen[0]['id']])
        second_device = scope['read_feed'](34, 100)
        assert second_device['events'] == [] and second_device['readEventIDs'] == [seen[0]['id']]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(lambda event: acknowledge([event['id']]), seen))
        shared = scope['read_feed'](34, 100)
        assert set(shared['readEventIDs']) == {event['id'] for event in seen}, 'concurrent acknowledgment lost another device update'
        receipt_path = root / 'read-state.json'
        receipt_bytes = receipt_path.read_bytes()
        acknowledge([seen[0]['id'], seen[0]['id'], str(uuid.uuid4())])
        assert receipt_path.read_bytes() == receipt_bytes, 'retry/expired IDs changed read state'
        acknowledge([seen[0]['id']], source_id=str(uuid.uuid4()), succeeds=False)
        acknowledge(['not-a-uuid'], succeeds=False)
        assert receipt_path.read_bytes() == receipt_bytes, 'invalid source/ID altered shared receipts'
        assert not scope['load_read_ids']({'sourceID': str(uuid.uuid4())}), 'old receipts crossed source identities'
        assert len(list((root / 'events').glob('*.json'))) == 34, 'acknowledgment deleted events'

        # Retention is writer-owned, bounded by count and age; reads do not prune.
        scope['MAX_EVENTS'] = 5
        scope['prune']()
        assert len(list((root / 'events').glob('*.json'))) == 5
        assert len(json.loads(receipt_path.read_text())['readEventIDs']) == 5
        files = scope['event_files']()
        os.utime(files[0].path, (time.time() - 31 * 86400,) * 2)
        assert len(scope['read_feed'](0, 100)['events']) == 4
        assert len(scope['read_feed'](34, 100)['readEventIDs']) == 4
        assert len(list((root / 'events').glob('*.json'))) == 5
        scope['prune']()
        assert len(list((root / 'events').glob('*.json'))) == 4
        assert len(json.loads(receipt_path.read_text())['readEventIDs']) == 4

        # Malformed configuration must remain byte-for-byte unchanged.
        hooks.write_bytes(b'{malformed')
        try:
            scope['install'](source.encode(), str(codex_directory))
            raise AssertionError('malformed hooks accepted')
        except (ValueError, json.JSONDecodeError):
            pass
        assert hooks.read_bytes() == b'{malformed'
        print('PASS: concurrent events/shared receipts, independent cursors, privacy, retention, idempotent setup, malformed-config preservation')


if __name__ == '__main__':
    main()
