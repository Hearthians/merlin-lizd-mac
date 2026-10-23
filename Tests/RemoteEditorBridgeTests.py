#!/usr/bin/env python3
"""Exercise the shipped remote editor helper without modifying real homes/hosts."""
import base64
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import termios
import time
import uuid

SOURCE_FILE = Path(__file__).resolve().parents[1] / 'Sources/TmuxHubCore/RemoteEditorBridge.swift'


def embedded(name):
    match = re.search(r'public static let ' + name + r' = #"""\n(.*?)\n    """#', SOURCE_FILE.read_text(), re.S)
    assert match, name
    return textwrap.dedent(match.group(1)) + '\n'


def scope_for(source, root):
    scope = {'__name__': 'isolated_bridge'}
    exec(compile(source, 'bridge.py', 'exec'), scope)
    scope['ROOT'] = str(root)
    return scope


def expect_failure(action):
    try:
        action()
    except (OSError, ValueError):
        return
    raise AssertionError('expected a rejection')


def read_output(fd, wait=.05):
    output = b''
    while select.select([fd], [], [], wait)[0]:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            output += chunk
        except OSError:
            break
    return output


class Picker(io.StringIO):
    def __init__(self, answer):
        super().__init__()
        self.answer = answer
    def readline(self, size=-1):
        return self.answer


def main():
    source = embedded('helperSource')
    shell = embedded('shellIntegrationContents')
    compile(source, 'bridge.py', 'exec')
    for executable in ('/bin/bash', '/bin/zsh'):
        if os.path.exists(executable):
            subprocess.run([executable, '-n'], input=shell.encode(), check=True)
    with tempfile.TemporaryDirectory(prefix='tmuxhub-editor-tests-') as temporary:
        root = Path(temporary) / 'bridge'
        home = Path(temporary) / 'fake-home'
        home.mkdir()
        (home / '.bashrc').write_text('export EXISTING_SETTING=yes\n')
        scope = scope_for(source, root)
        scope['install'](source.encode(), shell.encode(), str(home))
        first = (home / '.bashrc').read_bytes()
        assert first.startswith(b'export EXISTING_SETTING=yes\n')
        assert scope['install'](source.encode(), shell.encode(), str(home)) == []
        assert (home / '.bashrc').read_bytes() == first
        assert len(list(home.glob('.bashrc.tmuxhub-editor-backup-*'))) == 1
        assert stat.S_IMODE((root / 'bridge.py').stat().st_mode) == 0o600
        assert stat.S_IMODE((root / 'clients').stat().st_mode) == 0o700
        safe = root / 'safe'
        safe.write_text('unchanged')
        link = root / 'symlink'
        link.symlink_to(safe)
        expect_failure(lambda: scope['atomic_write'](str(link), b'changed'))
        assert safe.read_text() == 'unchanged'
        token = str(uuid.uuid4())
        client = {'token': token, 'device': 'Mac A', 'tty': '/dev/ttys-test', 'serverAddress': '10.1.2.3'}
        assert scope['choose_client']([client]) == client
        second = {**client, 'device': 'Mac B', 'token': str(uuid.uuid4())}
        assert scope['choose_client']([client, second], Picker('2\n')) == second
        assert scope['choose_client']([client, second], Picker('\n')) is None
        expect_failure(lambda: scope['choose_client']([client, second], Picker('all\n')))
        folder = root / 'folder with spaces # percent%中文'
        folder.mkdir()
        frame = scope['make_payload'](client, str(folder))
        payload = json.loads(base64.b64decode(frame[len(b'\x1b]777;tmuxhub-code;'):-1]))
        assert payload['path'] == str(folder) and payload['isDirectory'] is True
        assert payload['token'] == token and payload['serverAddress'] == '10.1.2.3'
        assert uuid.UUID(payload['requestID'])
        expect_failure(lambda: scope['make_payload'](client, 'bad\npath'))
        expect_failure(lambda: scope['make_payload'](client, 'x' * 5000))
        malformed = root / 'clients' / 'bad.json'
        malformed.write_text('{}')
        malformed.chmod(0o600)
        expect_failure(lambda: scope['read_registration'](str(malformed)))
        wrong_mode = root / 'clients' / 'public.json'
        wrong_mode.write_text('{}')
        wrong_mode.chmod(0o644)
        expect_failure(lambda: scope['read_registration'](str(wrong_mode)))

        # Preserve both native executable and explicit user alias/function definitions.
        native = root / 'native-bin'
        native.mkdir()
        (native / 'code').write_text('#!/bin/sh\nprintf "native:%s\\n" "$*"\n')
        (native / 'code').chmod(0o700)
        environment = {key: value for key, value in os.environ.items() if key not in ('TMUX', 'TMUX_PANE')}
        environment['PATH'] = str(native) + os.pathsep + environment.get('PATH', '')
        for executable in ('/bin/bash', '/bin/zsh'):
            if not os.path.exists(executable):
                continue
            result = subprocess.run([executable, '-c', shell + '\ncode "path with spaces"'],
                                    env=environment, check=True, stdout=subprocess.PIPE, text=True)
            assert result.stdout.strip() == 'native:path with spaces', result.stdout
            result = subprocess.run([executable, '-c', 'code() { echo original-function; };\n' + shell + '\ncode'],
                                    env=environment, check=True, stdout=subprocess.PIPE, text=True)
            assert result.stdout.strip() == 'original-function', result.stdout

        terminal_picker_test(source, root, temporary)
        tmux = shutil.which('tmux')
        if tmux:
            live_tmux_test(source, scope, root, temporary, tmux, folder)
        else:
            print('SKIP: live multi-client test (tmux unavailable)')
    print('Remote editor bridge checks passed.')



def terminal_picker_test(source, root, temporary):
    source_path = Path(temporary) / 'picker-bridge.py'
    source_path.write_text(source)
    bootstrap = "s={'__name__':'test'};exec(compile(open(%r).read(),%r,'exec'),s);print('CHOSEN='+s['choose_client']([{'device':'Mac A','tty':'/dev/a'},{'device':'Mac B','tty':'/dev/b'}])['device'],flush=True)" % (str(source_path), str(source_path))
    previous_hup = signal.signal(signal.SIGHUP, signal.SIG_IGN)
    master, slave = pty.openpty()
    def become_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    process = subprocess.Popen([sys.executable, '-c', bootstrap], stdin=slave, stdout=slave, stderr=slave,
                               preexec_fn=become_terminal)
    try:
        output = b''
        deadline = time.monotonic() + 3
        while b'Device number' not in output and time.monotonic() < deadline:
            output += read_output(master)
        assert b'Device number' in output, output
        os.write(master, b'2\n')
        deadline = time.monotonic() + 3
        while b'CHOSEN=Mac B' not in output and time.monotonic() < deadline:
            output += read_output(master)
        assert b'CHOSEN=Mac B' in output, output
    finally:
        os.close(master)
        os.close(slave)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        signal.signal(signal.SIGHUP, previous_hup)


def live_tmux_test(source, scope, root, temporary, tmux, folder):
    socket_path = str(Path(temporary) / 'tmux.sock')
    base = [tmux, '-S', socket_path]
    clients = []
    previous_hup = signal.signal(signal.SIGHUP, signal.SIG_IGN)
    tmux_variables = {key: os.environ.get(key) for key in ('TMUX', 'TMUX_PANE')}
    source_path = Path(temporary) / 'bridge.py'
    source_path.write_text(source)
    try:
        subprocess.run(base + ['-f', '/dev/null', 'new-session', '-d', '-s', 'bridge-test'],
                       check=True, start_new_session=True)
        pane_info = subprocess.check_output(base + ['display-message', '-p', '-t', 'bridge-test',
                                                   '#{pid}\t#{pane_id}']).decode().strip().split('\t')
        os.environ['TMUX'] = socket_path + ',' + pane_info[0] + ',0'
        os.environ['TMUX_PANE'] = pane_info[1]
        for name in ('Mac A', 'Mac B'):
            master, slave = pty.openpty()
            token = str(uuid.uuid4())
            bootstrap = "s={'__name__':'isolated_bridge'};exec(compile(open(%r).read(),%r,'exec'),s);s['ROOT']=%r;s['register'](%r,%r,int(__import__('sys').argv[1]))" % (
                str(source_path), str(source_path), str(root), token, name)
            attach_arguments = base + ['attach-session', '-t', 'bridge-test']
            if name == 'Mac A':
                attach = 'exec ' + ' '.join(map(shlex.quote, attach_arguments))
            else:
                # Notification launchers exec tmux from Python under a waiting shell.
                nested = 'import os;os.execv(%r,%r)' % (tmux, attach_arguments)
                attach = ' '.join(map(shlex.quote, [sys.executable, '-c', nested])) + '; status=$?; exit "$status"'
            command = ' '.join(map(shlex.quote, [sys.executable, '-c', bootstrap])) + ' "$$"; ' + attach
            process = subprocess.Popen(['/bin/sh', '-c', command], stdin=slave, stdout=slave, stderr=slave,
                                       env={**os.environ, 'TERM': 'xterm-256color', 'SSH_CONNECTION': '10.0.0.2 50000 10.1.2.3 22'},
                                       start_new_session=True)
            clients.append((master, slave, process, token))
            time.sleep(.25)
            read_output(master)
        eligible = scope['eligible_clients']()
        assert len(eligible) == 2, eligible
        assert {entry['token'] for entry in eligible} == {item[3] for item in clients}
        for master, slave, process, token in clients:
            read_output(master)
        chosen = next(item for item in eligible if item['device'] == 'Mac A')
        scope['send_request'](chosen, str(folder))
        time.sleep(.1)
        first = read_output(clients[0][0])
        second = read_output(clients[1][0])
        assert b'\x1b]777;tmuxhub-code;' in first, first
        assert b'\x1b]777;tmuxhub-code;' not in second, second
        # A stale/reused PID, a registration from a different node or a detached client cannot route.
        record_path = root / 'clients' / (chosen['token'] + '.json')
        original = record_path.read_text()
        record = json.loads(original)
        record['pid'] += 100000
        record_path.write_text(json.dumps(record))
        assert len(scope['eligible_clients']()) == 1
        record['pid'] = chosen['pid']
        record['hostname'] = 'some-other-node'
        record_path.write_text(json.dumps(record))
        assert len(scope['eligible_clients']()) == 1
        record_path.write_text(original)
        subprocess.run(base + ['detach-client', '-t', chosen['tty']], check=True)
        assert len(scope['eligible_clients']()) == 1
        expect_failure(lambda: scope['send_request'](chosen, str(folder)))
        print('PASS: two live tmux clients; only explicitly selected device receives OSC.')
    finally:
        subprocess.run(base + ['kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       start_new_session=True)
        for master, slave, process, token in clients:
            read_output(master)
            os.close(master)
            os.close(slave)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        for key, value in tmux_variables.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        signal.signal(signal.SIGHUP, previous_hup)


if __name__ == '__main__':
    main()
