import Foundation

/// A per-connection terminal channel. Editor requests go directly to the outer
/// SSH tty, so tmux never broadcasts them to another attached device.
public enum RemoteEditorBridge {
    public static let oscCode = 777
    public static let oscPrefix = "tmuxhub-code;"

    public static func wrap(command: CommandSpec, token: String, deviceName: String) throws -> CommandSpec {
        guard UUID(uuidString: token) != nil,
            command.executable == "/usr/bin/ssh", let original = command.arguments.last,
            !original.isEmpty else { throw CommandValidationError.invalidSSHDestination }
        let source = Data(helperSource.utf8).base64EncodedString()
        let shell = Data(shellIntegrationContents.utf8).base64EncodedString()
        let bootstrap = "import base64;exec(compile(base64.b64decode(" + shellPythonLiteral(source) + "),'tmuxhub-remote-editor','exec'))"
        let registration = ["python3", "-c", bootstrap, "bootstrap", source, shell, token, deviceName]
            .map(shellQuote).joined(separator: " ")
        var arguments = command.arguments
        // Install on the actual connection before new tmux shells start. A setup
        // failure must still launch the user's original SSH/tmux command.
        let script = registration + " \"$$\" >/dev/null 2>&1"
            + " || printf '%s\\r\\n' 'TmuxHub: automatic code setup failed; Python 3 and a writable home are required. Retry from host settings.' >&2; "
            + original
        // The SSH login shell may be fish/csh. Keep POSIX syntax inside /bin/sh.
        arguments[arguments.count - 1] = "exec /bin/sh -c " + shellQuote(script)
        return CommandSpec(executable: command.executable, arguments: arguments, environment: command.environment)
    }

    public static func installCommand(destination: String) throws -> CommandSpec {
        guard IdentifierValidator.isSSHDestination(destination) else {
            throw CommandValidationError.invalidSSHDestination
        }
        let source = Data(helperSource.utf8).base64EncodedString()
        let shell = Data(shellIntegrationContents.utf8).base64EncodedString()
        let bootstrap = "import base64;exec(compile(base64.b64decode(" + shellPythonLiteral(source) + "),'tmuxhub-remote-editor','exec'))"
        let remote = ["python3", "-c", bootstrap, "install", source, shell].map(shellQuote).joined(separator: " ")
        return CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            destination, remote,
        ])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellPythonLiteral(_ value: String) -> String { "'" + value + "'" }

    public static let shellIntegrationContents = #"""
    # TmuxHub remote editor shell integration v1
    # Leave the existing executable untouched; `command code` always invokes it.
    _tmuxhub_editor_code() {
        if [ -z "${TMUX-}" ] || [ -n "${VSCODE_IPC_HOOK_CLI-}" ]; then
            command code "$@"
            return $?
        fi
        local _tmuxhub_editor_status
        if python3 "$HOME/.local/share/tmuxhub/remote-editor/bridge.py" open "$@"; then
            return 0
        else
            _tmuxhub_editor_status=$?
        fi
        if [ "$_tmuxhub_editor_status" -eq 20 ]; then
            command code "$@"
        else
            return "$_tmuxhub_editor_status"
        fi
    }
    # Preserve an existing user alias/function. The explicit tmuxhub-code name remains available.
    tmuxhub-code() { _tmuxhub_editor_code "$@"; }
    if ! typeset -f code >/dev/null 2>&1 && ! alias code >/dev/null 2>&1; then
        code() { _tmuxhub_editor_code "$@"; }
    fi
    """# + "\n"

    public static let helperSource = #"""
    # TmuxHub remote editor bridge v1
    import base64
    import fcntl
    import io
    import json
    import os
    import re
    import select
    import shlex
    import socket
    import stat
    import subprocess
    import sys
    import tempfile
    import time
    import uuid

    ROOT = os.path.expanduser('~/.local/share/tmuxhub/remote-editor')
    MAX_PAYLOAD = 16384
    TOKEN = re.compile(r'^[A-Za-z0-9_-]{16,128}$')
    MARKER = '# TmuxHub remote editor bridge v1'
    LEGACY_SOURCE_LINE = '[ ! -r "$HOME/.local/share/tmuxhub/remote-editor/shell.sh" ] || . "$HOME/.local/share/tmuxhub/remote-editor/shell.sh" # TmuxHub remote editor'
    SOURCE_LINE = 'if [ -n "${BASH_VERSION-}${ZSH_VERSION-}" ] && [ -r "$HOME/.local/share/tmuxhub/remote-editor/shell.sh" ]; then . "$HOME/.local/share/tmuxhub/remote-editor/shell.sh"; fi # TmuxHub remote editor'


    def private_dir(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Unsafe remote editor directory: ' + path)
        os.chmod(path, 0o700)


    def atomic_write(path, data, mode=0o600):
        if os.path.lexists(path):
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('Unsafe remote editor file: ' + path)
        fd, temporary = tempfile.mkstemp(prefix='.tmuxhub-editor-', dir=os.path.dirname(path))
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


    def clean_label(value):
        return ''.join(c for c in value if ord(c) >= 32 and not 127 <= ord(c) <= 159)[:100]


    def register(token, device, pid):
        if not TOKEN.fullmatch(token) or pid <= 1:
            raise ValueError('Invalid client registration')
        tty = os.ttyname(0)
        info = os.stat(tty)
        if not stat.S_ISCHR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Invalid client terminal')
        private_dir(ROOT)
        directory = os.path.join(ROOT, 'clients')
        private_dir(directory)
        connection = os.environ.get('SSH_CONNECTION', '').split()
        record = {'version': 1, 'token': token, 'device': clean_label(device) or 'Mac',
                  'pid': pid, 'tty': tty, 'deviceID': info.st_rdev, 'inode': info.st_ino,
                  'hostname': socket.gethostname(), 'serverAddress': connection[2] if len(connection) == 4 else None,
                  'createdAt': time.time()}
        # Only discard dead registrations from this node; home directories may be shared.
        for name in sorted(os.listdir(directory))[:1024]:
            path = os.path.join(directory, name)
            try:
                old = read_registration(path)
                if old['hostname'] == record['hostname']:
                    try:
                        os.kill(old['pid'], 0)
                    except ProcessLookupError:
                        os.unlink(path)
            except (OSError, ValueError, KeyError, TypeError):
                pass
        atomic_write(os.path.join(directory, token + '.json'), json.dumps(record).encode())


    def read_registration(path):
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > MAX_PAYLOAD):
                raise ValueError('Unsafe client registration')
            record = json.loads(stream.read(MAX_PAYLOAD + 1))
        if (record.get('version') != 1 or not TOKEN.fullmatch(record.get('token', ''))
                or not isinstance(record.get('pid'), int) or record['pid'] <= 1
                or not isinstance(record.get('tty'), str) or not record['tty'].startswith('/dev/')
                or not isinstance(record.get('hostname'), str)):
            raise ValueError('Invalid client registration')
        return record


    def tmux_output(arguments):
        value = os.environ.get('TMUX', '')
        socket_path, separator, rest = value.rpartition(',')
        socket_path, separator, rest = socket_path.rpartition(',')
        if not separator or not socket_path.startswith('/') or '\0' in socket_path:
            raise ValueError('A tmux pane is required')
        # HPC login nodes may still use Python 3.6 (before the text keyword alias).
        completed = subprocess.run(['tmux', '-S', socket_path] + arguments,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=5, check=True, universal_newlines=True)
        if len(completed.stdout) > 1024 * 1024:
            raise ValueError('Too many tmux clients')
        return completed.stdout


    def process_descends_from(pid, ancestor):
        # Notification/Herdr launchers may leave an intermediate shell alive.
        # Match that connection's descendant tmux client, never another tty's client.
        visited = set()
        for _ in range(16):
            if pid == ancestor:
                return True
            if pid <= 1 or pid in visited:
                return False
            visited.add(pid)
            try:
                status_path = '/proc/%d/status' % pid
                if os.path.exists(status_path):
                    with open(status_path) as stream:
                        parent = next((line.split()[1] for line in stream if line.startswith('PPid:')), '')
                else:
                    parent = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)],
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                            universal_newlines=True, timeout=1, check=True).stdout.strip()
                if not parent.isdigit():
                    return False
                pid = int(parent)
            except (OSError, ValueError, subprocess.SubprocessError):
                return False
        return False


    def eligible_clients():
        pane = os.environ.get('TMUX_PANE', '')
        if not re.fullmatch(r'%[0-9]+', pane):
            return []
        directory = os.path.join(ROOT, 'clients')
        try:
            info = os.lstat(directory)
        except FileNotFoundError:
            return []
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077):
            raise ValueError('Unsafe client directory')
        # A window can be linked into several sessions. Include every session containing this pane.
        sessions = set()
        for line in tmux_output(['list-panes', '-a', '-F', '#{pane_id}\t#{session_id}']).splitlines():
            fields = line.split('\t')
            if len(fields) == 2 and fields[0] == pane:
                sessions.add(fields[1])
        clients = set()
        for line in tmux_output(['list-clients', '-F', '#{client_tty}\t#{client_pid}\t#{session_id}']).splitlines():
            fields = line.split('\t')
            if len(fields) == 3 and fields[1].isdigit() and fields[2] in sessions:
                clients.add((fields[0], int(fields[1])))
        result = []
        for name in sorted(os.listdir(directory))[:1024]:
            if not name.endswith('.json'):
                continue
            try:
                record = read_registration(os.path.join(directory, name))
                if record['hostname'] != socket.gethostname():
                    continue
                if not any(tty == record['tty'] and process_descends_from(pid, record['pid']) for tty, pid in clients):
                    continue
                tty_info = os.stat(record['tty'])
                if (not stat.S_ISCHR(tty_info.st_mode) or tty_info.st_uid != os.getuid()
                        or tty_info.st_rdev != record.get('deviceID') or tty_info.st_ino != record.get('inode')):
                    continue
                result.append(record)
            except (OSError, ValueError, KeyError, TypeError):
                continue
        # A restarted app may leave a previous token for the same client. Never send twice.
        latest = {}
        for record in result:
            key = (record['tty'], record['pid'])
            if record.get('createdAt', 0) > latest.get(key, {}).get('createdAt', -1):
                latest[key] = record
        return sorted(latest.values(), key=lambda item: (item.get('device', ''), item['tty']))


    def choose_client(clients, stream=None):
        if not clients:
            return None
        if len(clients) == 1:
            return clients[0]
        if stream is None:
            # Text-mode r+ uses a seekable BufferedRandom; terminal devices are not seekable.
            with io.TextIOWrapper(open('/dev/tty', 'rb+', buffering=0), encoding='utf-8', line_buffering=True) as terminal:
                return choose_client(clients, terminal)
        stream.write('Several TmuxHub devices are attached. Open VS Code on:\n')
        for index, item in enumerate(clients, 1):
            stream.write('  %d. %s (%s)\n' % (index, clean_label(item.get('device', 'Mac')), item['tty']))
        stream.write('Device number (Enter to cancel): ')
        stream.flush()
        answer = stream.readline(32).strip()
        if not answer:
            return None
        if not answer.isdigit() or not 1 <= int(answer) <= len(clients):
            raise ValueError('Invalid device number; no editor was opened')
        return clients[int(answer) - 1]


    def make_payload(client, path):
        absolute = os.path.abspath(os.path.expanduser(path))
        if len(absolute.encode()) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in absolute):
            raise ValueError('The path contains unsupported control characters or is too long')
        # Folders must exist. Nonexistent paths are opened as files, matching the ordinary code CLI.
        record = {'version': 1, 'requestID': str(uuid.uuid4()), 'token': client['token'],
                  'path': absolute, 'isDirectory': os.path.isdir(absolute),
                  'hostname': socket.gethostname(), 'serverAddress': client.get('serverAddress')}
        encoded = base64.b64encode(json.dumps(record, ensure_ascii=False).encode())
        frame = b'\x1b]777;tmuxhub-code;' + encoded + b'\x07'
        if len(frame) > MAX_PAYLOAD:
            raise ValueError('The editor request is too large')
        return frame


    def send_request(client, path):
        # Revalidate immediately before opening the outer SSH tty, not the tmux pane tty.
        current = next((entry for entry in eligible_clients() if entry['token'] == client['token']), None)
        if current is None:
            raise ValueError('That TmuxHub connection has closed; reconnect and try again')
        frame = make_payload(current, path)
        fd = os.open(current['tty'], os.O_WRONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
        try:
            info = os.fstat(fd)
            if (not stat.S_ISCHR(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_rdev != current['deviceID'] or info.st_ino != current['inode']):
                raise ValueError('The client terminal changed; try again')
            pending = memoryview(frame)
            deadline = time.monotonic() + 2
            while pending:
                if time.monotonic() >= deadline or not select.select([], [fd], [], max(0, deadline - time.monotonic()))[1]:
                    raise ValueError('The client terminal is not accepting requests')
                try:
                    pending = pending[os.write(fd, pending):]
                except BlockingIOError:
                    continue
        finally:
            os.close(fd)


    def open_editor(arguments):
        # Outside a compatible TmuxHub pane, the shell function delegates to native code.
        if not os.environ.get('TMUX') or os.environ.get('VSCODE_IPC_HOOK_CLI'):
            return 20
        clients = eligible_clients()
        if not clients:
            return 20
        if arguments in (['--help'], ['-h']):
            print('Usage: code [path]\nOpens a remote folder or file in VS Code on a connected TmuxHub device.\nUse command code for the server\'s native VS Code CLI.')
            return 0
        if arguments and arguments[0] == '--':
            arguments = arguments[1:]
        elif any(value.startswith('-') for value in arguments):
            raise ValueError('This bridge supports code [path]. Use command code for other CLI options')
        if len(arguments) > 1:
            raise ValueError('Open one file or folder at a time; quote paths containing spaces')
        path = arguments[0] if arguments else '.'
        selected = choose_client(clients)
        if selected is None:
            print('No editor was opened.')
            return 0
        send_request(selected, path)
        print('Sent to VS Code on %s.' % clean_label(selected.get('device', 'Mac')))
        return 0


    def write_if_changed(path, contents):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
        except FileNotFoundError:
            return atomic_write(path, contents)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('Unsafe remote editor file: ' + path)
            if info.st_size == len(contents) and stream.read(len(contents) + 1) == contents:
                return
        atomic_write(path, contents)


    def install(source, shell_source, home=None):
        if not source.startswith(MARKER.encode()) or len(source) > 100000 or len(shell_source) > 20000:
            raise ValueError('Invalid remote editor installation')
        private_dir(ROOT)
        # Simultaneous attaches, including devices sharing an HPC home, must not
        # race when appending startup hooks. Never delay a terminal indefinitely.
        lock = os.open(os.path.join(ROOT, 'install.lock'),
                       os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            info = os.fstat(lock)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('Unsafe remote editor setup lock')
            deadline = time.monotonic() + 3
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise ValueError('Remote editor setup is busy; reconnect to retry')
                    time.sleep(0.05)
            return install_locked(source, shell_source, home)
        finally:
            os.close(lock)


    def install_locked(source, shell_source, home=None):
        home = os.path.abspath(home or os.path.expanduser('~'))
        private_dir(os.path.join(ROOT, 'clients'))
        write_if_changed(os.path.join(ROOT, 'bridge.py'), source)
        write_if_changed(os.path.join(ROOT, 'shell.sh'), shell_source)
        # tmux normally starts a login shell. Bash reads only the first existing
        # login file, so do not introduce a .bash_profile that shadows .profile.
        login = next((name for name in ('.bash_profile', '.bash_login', '.profile')
                      if os.path.lexists(os.path.join(home, name))), '.profile')
        changed = []
        for filename in ('.bashrc', '.zshrc', login):
            path = os.path.join(home, filename)
            # Honor owned dotfile symlinks (for example a dotfiles checkout).
            target = os.path.realpath(path)
            if os.path.exists(target):
                info = os.stat(target)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                    raise ValueError('Unsafe shell configuration: ' + path)
                with open(target, 'rb') as stream:
                    previous = stream.read(2 * 1024 * 1024 + 1)
                if len(previous) > 2 * 1024 * 1024:
                    raise ValueError('Shell configuration is too large: ' + path)
                mode = stat.S_IMODE(info.st_mode)
            elif os.path.lexists(path):
                raise ValueError('Broken shell configuration symlink: ' + path)
            else:
                previous, mode = b'', 0o600
            lines = previous.splitlines()
            if SOURCE_LINE.encode() in lines and LEGACY_SOURCE_LINE.encode() not in lines:
                continue
            managed = (SOURCE_LINE.encode(), LEGACY_SOURCE_LINE.encode())
            preserved = b''.join(line for line in previous.splitlines(keepends=True)
                                 if line.rstrip(b'\r\n') not in managed)
            updated = preserved + (b'\n' if preserved and not preserved.endswith(b'\n') else b'') + SOURCE_LINE.encode() + b'\n'
            if os.path.exists(target):
                backup = target + '.tmuxhub-editor-backup-' + uuid.uuid4().hex[:8]
                atomic_write(backup, previous, mode)
            atomic_write(target, updated, mode)
            changed.append(filename)
        print('TMUXHUB_REMOTE_EDITOR_INSTALLED_V1')
        print('New Bash/Zsh shells are ready. Existing shells: . ~/.local/share/tmuxhub/remote-editor/shell.sh')
        return changed


    def main():
        try:
            action = sys.argv[1]
            if action == 'bootstrap' and len(sys.argv) == 7:
                # Check the live tty before installing anything (also protects
                # noninteractive invocations from touching shell startup files).
                register(sys.argv[4], sys.argv[5], int(sys.argv[6]))
                install(base64.b64decode(sys.argv[2], validate=True), base64.b64decode(sys.argv[3], validate=True))
                return 0
            if action == 'register' and len(sys.argv) == 5:
                register(sys.argv[2], sys.argv[3], int(sys.argv[4]))
                return 0
            if action == 'install' and len(sys.argv) == 4:
                install(base64.b64decode(sys.argv[2], validate=True), base64.b64decode(sys.argv[3], validate=True))
                return 0
            if action == 'open':
                return open_editor(sys.argv[2:])
            raise ValueError('Invalid remote editor command')
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print('TmuxHub: ' + str(error), file=sys.stderr)
            return 1


    if __name__ == '__main__':
        sys.exit(main())
    """# + "\n"
}
