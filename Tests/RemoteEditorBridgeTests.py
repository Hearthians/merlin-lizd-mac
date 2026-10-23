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

        default_installation_tests(source, shell, temporary)
        terminal_picker_test(source, root, temporary)
        tmux = shutil.which('tmux')
        if tmux:
            live_tmux_test(source, scope, root, temporary, tmux, folder)
        else:
            print('SKIP: live multi-client test (tmux unavailable)')
    print('Remote editor bridge checks passed.')



def default_installation_tests(source, shell, temporary):
    # Bash login shells use the first available profile, which need not source .bashrc.
    for selected in ('.bash_profile', '.bash_login', '.profile', None):
        home = Path(temporary) / ('login-' + (selected or 'new').lstrip('.'))
        home.mkdir()
        root = home / '.local/share/tmuxhub/remote-editor'
        scope = scope_for(source, root)
        names = ['.bash_profile', '.bash_login', '.profile']
        if selected:
            for name in names[names.index(selected):]:
                (home / name).write_text('export EXISTING_PROFILE=preserved\n')
        scope['install'](source.encode(), shell.encode(), str(home))
        effective = home / (selected or '.profile')
        assert scope['SOURCE_LINE'] in effective.read_text(), effective
        if selected:
            for name in names[names.index(selected) + 1:]:
                assert (home / name).read_text() == 'export EXISTING_PROFILE=preserved\n'
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('TMUX', 'TMUX_PANE', 'BASH_ENV', 'ENV', 'ZDOTDIR')}
        environment['HOME'] = str(home)
        loaded = subprocess.run(['/bin/bash', '--norc', '--login', '-c', 'type code; type tmuxhub-code'],
                                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, check=True)
        assert 'code is a function' in loaded.stdout, loaded
        # Simulate a non-Bash/non-Zsh reader of the common .profile file.
        if effective.name == '.profile':
            loaded = subprocess.run(['/bin/sh', '-c',
                                     'unset BASH_VERSION ZSH_VERSION; . "$HOME/.profile"; '
                                     'if command -v _tmuxhub_editor_code >/dev/null 2>&1; then exit 17; fi; printf safe'],
                                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, check=True)
            assert loaded.stdout == 'safe', loaded

        installed = [root / 'bridge.py', root / 'shell.sh', home / '.bashrc', home / '.zshrc', effective]
        before = {path: (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes()) for path in installed}
        backups = sorted(str(path) for path in home.glob('.*.tmuxhub-editor-backup-*'))
        assert scope['install'](source.encode(), shell.encode(), str(home)) == []
        assert before == {path: (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes()) for path in installed}
        assert backups == sorted(str(path) for path in home.glob('.*.tmuxhub-editor-backup-*'))

    # Failed/no-tty registration must never mutate remote startup files.
    home = Path(temporary) / 'no-tty-home'
    home.mkdir()
    (home / '.bashrc').write_text('export DO_NOT_CHANGE=1\n')
    bootstrap_source = Path(temporary) / 'bootstrap-source.py'
    bootstrap_source.write_text(source)
    result = subprocess.run([
        sys.executable, str(bootstrap_source), 'bootstrap',
        base64.b64encode(source.encode()).decode(), base64.b64encode(shell.encode()).decode(),
        str(uuid.uuid4()), 'Mac without a terminal', str(os.getpid()),
    ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, 'HOME': str(home)}, start_new_session=True)
    assert result.returncode != 0
    assert (home / '.bashrc').read_text() == 'export DO_NOT_CHANGE=1\n'
    assert not (home / '.profile').exists()
    assert not (home / '.local/share/tmuxhub/remote-editor').exists()

    # Repeated auto-setup upgrades the prior unguarded marker rather than duplicating it.
    home = Path(temporary) / 'legacy-startup'
    home.mkdir()
    root = home / '.local/share/tmuxhub/remote-editor'
    legacy = '[ ! -r "$HOME/.local/share/tmuxhub/remote-editor/shell.sh" ] || . "$HOME/.local/share/tmuxhub/remote-editor/shell.sh" # TmuxHub remote editor'
    (home / '.bashrc').write_text('export BEFORE=1\n' + legacy + '\nexport AFTER=2\n')
    scope = scope_for(source, root)
    scope['install'](source.encode(), shell.encode(), str(home))
    updated = (home / '.bashrc').read_text()
    assert updated.count('# TmuxHub remote editor') == 1
    assert scope['SOURCE_LINE'] in updated
    assert 'export BEFORE=1\n' in updated and 'export AFTER=2\n' in updated

    # Devices may reconnect to a shared home at once; only one edits the startup files.
    home = Path(temporary) / 'concurrent-startup'
    home.mkdir()
    (home / '.bashrc').write_text('export ORIGINAL=preserved\n')
    root = home / '.local/share/tmuxhub/remote-editor'
    source_file = Path(temporary) / 'installer-source.py'
    source_file.write_text(source)
    worker = (
        "import base64; s={'__name__':'test'}; "
        "exec(compile(open(%r).read(),%r,'exec'),s); s['ROOT']=%r; "
        "s['install'](open(%r,'rb').read(),base64.b64decode(%r),%r)"
    ) % (str(source_file), str(source_file), str(root), str(source_file),
         base64.b64encode(shell.encode()).decode(), str(home))
    processes = [subprocess.Popen([sys.executable, '-c', worker],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(6)]
    for process in processes:
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, (stdout, stderr)
    scope = scope_for(source, root)
    assert (home / '.bashrc').read_text().count(scope['SOURCE_LINE']) == 1
    assert len(list(home.glob('.bashrc.tmuxhub-editor-backup-*'))) == 1
    assert (root / 'bridge.py').read_bytes() == source.encode()
    assert (root / 'shell.sh').read_bytes() == shell.encode()

    # Unsafe existing helper files cannot hang automatic setup before SSH attaches.
    fifo = root / 'fifo-helper'
    os.mkfifo(fifo, 0o600)
    reject_fifo = (
        "s={'__name__':'test'}; exec(compile(open(%r).read(),%r,'exec'),s); "
        "s['write_if_changed'](%r,b'new helper')"
    ) % (str(source_file), str(source_file), str(fifo))
    result = subprocess.run([sys.executable, '-c', reject_fifo], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=2)
    assert result.returncode != 0
    assert stat.S_ISFIFO(fifo.stat().st_mode)

    # A busy installer has a bounded wait. Advance its private clock to avoid a slow test.
    descriptor = os.open(root / 'install.lock', os.O_RDWR)
    original_time = scope['time']
    class FastClock:
        value = 0
        @classmethod
        def monotonic(cls):
            cls.value += 10
            return cls.value
        @staticmethod
        def sleep(seconds):
            pass
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        scope['time'] = FastClock
        expect_failure(lambda: scope['install'](source.encode(), shell.encode(), str(home)))
    finally:
        scope['time'] = original_time
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    print('PASS: automatic setup covers login shells, idempotence, concurrent devices and bounded locking.')


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
