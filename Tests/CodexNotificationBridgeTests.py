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
        # tmux routing is bound to the actual server, socket and originating pane.
        actual_os, actual_run = scope['os'], scope['subprocess'].run
        requested = []
        fields = ['research session', '$3', '123456', '4321', '@7', '%5', '/tmp/tmux-test/default']
        def tmux_result(argv, **kwargs):
            requested.append((argv, kwargs))
            return SimpleNamespace(stdout=('\t'.join(fields) + '\n').encode())
        try:
            scope['os'] = SimpleNamespace(environ={'TMUX': '/tmp/tmux-test/default,4321,0', 'TMUX_PANE': '%5'})
            scope['subprocess'].run = tmux_result
            tmux_metadata = scope['tmux_context']()
            assert tmux_metadata == {'tmuxSession': 'research session', 'tmuxSessionID': '$3',
                                     'tmuxSessionCreated': 123456, 'tmuxServerPID': 4321,
                                     'tmuxWindow': '@7', 'tmuxPane': '%5', 'tmuxSocket': '/tmp/tmux-test/default'}
            assert requested[-1][0][:6] == ['tmux', '-S', '/tmp/tmux-test/default', 'display-message', '-p', '-t']
            assert requested[-1][0][6] == '%5' and requested[-1][1]['timeout'] == 0.8
            assert 'shell' not in requested[-1][1]
            for position, invalid_value in [(5, '%6'), (6, '/tmp/another-server/default'),
                                            (1, '$3;bad'), (4, '%7'), (2, '-1'), (3, '0')]:
                previous = fields[position]
                fields[position] = invalid_value
                assert scope['tmux_context']() == {}, (position, invalid_value)
                fields[position] = previous
            scope['os'] = SimpleNamespace(environ={'TMUX': '/tmp/tmux-test/default,4321,0', 'TMUX_PANE': '%5;bad'})
            before = len(requested)
            assert scope['tmux_context']() == {} and len(requested) == before
        finally:
            scope['os'], scope['subprocess'].run = actual_os, actual_run

        # Desktop hook sessions may use an engine ID different from the chat ID.
        desktop_id = str(uuid.uuid4())
        transcript = codex_directory / 'sessions' / '2026' / '10' / '22' / f'rollout-2026-10-22T10-00-00-{desktop_id}.jsonl'
        transcript.parent.mkdir(parents=True)
        metadata = {'type': 'session_meta', 'payload': {'id': desktop_id, 'originator': 'Codex Desktop'}}
        transcript.write_text(json.dumps(metadata) + '\nsecret transcript never copied\n')
        payload = {'session_id': str(uuid.uuid4()), 'transcript_path': str(transcript)}
        context = scope['desktop_context'](payload, str(codex_directory))
        assert context == {'desktopThreadID': desktop_id}
        assert 'secret' not in json.dumps(context) and 'transcript_path' not in context
        # A bare environment ID, matching cwd, or non-desktop header is insufficient.
        assert scope['desktop_context']({'session_id': desktop_id}, str(codex_directory)) == {}
        metadata['payload']['originator'] = 'codex_vscode'
        transcript.write_text(json.dumps(metadata) + '\n')
        assert scope['desktop_context'](payload, str(codex_directory)) == {}
        metadata['payload']['originator'] = 'Codex Desktop'
        metadata['payload']['id'] = str(uuid.uuid4())
        transcript.write_text(json.dumps(metadata) + '\n')
        assert scope['desktop_context'](payload, str(codex_directory)) == {}
        assert scope['desktop_context']({'transcript_path': str(hooks)}, str(codex_directory)) == {}
        transcript.write_bytes(b'x' * 262145 + b'\n')
        assert scope['desktop_context'](payload, str(codex_directory)) == {}
        print('PASS: concurrent events/shared receipts, independent cursors, privacy, retention, idempotent setup, malformed-config preservation, verified desktop routing')


if __name__ == '__main__':
    main()
