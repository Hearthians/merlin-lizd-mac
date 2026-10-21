import Foundation

/// Installs a per-user event feed without changing Codex's feature flags or
/// trust decisions. All consumers keep their own cursors; reading never drains
/// or acknowledges an event on the host.
public enum CodexNotificationBridge {
    static func installCommand(destination: String?) throws -> CommandSpec {
        let encoded = Data(helperSource.utf8).base64EncodedString()
        let bootstrap = "import base64;exec(compile(base64.b64decode(\"\(encoded)\"),\"tmuxhub-codex-bridge\",\"exec\"))"
        return try command(arguments: ["python3", "-c", bootstrap, "install", encoded], destination: destination)
    }

    static func readCommand(destination: String?, after: Int, limit: Int) throws -> CommandSpec {
        guard after >= 0, (1...100).contains(limit) else { throw CodexNotificationError.invalidCursor }
        return try installedCommand(arguments: ["read", String(after), String(limit)], destination: destination)
    }

    static func markReadCommand(destination: String?, sourceID: String, eventIDs: [String]) throws -> CommandSpec {
        guard UUID(uuidString: sourceID) != nil, eventIDs.count <= 100,
            eventIDs.allSatisfy({ UUID(uuidString: $0) != nil })
        else { throw CodexNotificationError.invalidResponse }
        struct Request: Encodable { let sourceID: String; let eventIDs: [String] }
        let encoded = try JSONEncoder().encode(Request(sourceID: sourceID, eventIDs: eventIDs)).base64EncodedString()
        return try installedCommand(arguments: ["ack", encoded], destination: destination)
    }

    private static func installedCommand(arguments: [String], destination: String?) throws -> CommandSpec {
        let bootstrap = """
        import os,runpy,sys
        path=os.path.expanduser('~/.local/share/tmuxhub/codex-notifications/bridge.py')
        if not os.path.isfile(path):
            sys.stderr.write('TMUXHUB_NOT_INSTALLED\\n')
            sys.exit(20)
        sys.argv=[path]+sys.argv[1:]
        runpy.run_path(path,run_name='__main__')
        """
        return try command(arguments: ["python3", "-c", bootstrap] + arguments, destination: destination)
    }

    private static func command(arguments: [String], destination: String?) throws -> CommandSpec {
        if let destination {
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CodexNotificationError.invalidDestination
            }
            return CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                destination, arguments.map(shellQuote).joined(separator: " "),
            ])
        }
        return CommandSpec(executable: "/usr/bin/env", arguments: arguments)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Reviewed against https://learn.chatgpt.com/docs/hooks. The recorder only
    // returns {}, never approval/continuation decisions or model context.
    static let helperSource = #"""
    # TmuxHub Codex notification bridge v1
    import base64
    import contextlib
    import datetime
    import fcntl
    import json
    import os
    import re
    import shlex
    import shutil
    import socket
    import stat
    import subprocess
    import sys
    import tempfile
    import time
    import uuid

    MAX_EVENTS = 2000
    MAX_AGE = 30 * 86400
    MAX_INPUT = 2 * 1024 * 1024
    EVENT_NAMES = {'Stop': 'turnCompleted', 'PermissionRequest': 'approvalRequested', 'UserPromptSubmit': 'turnStarted'}
    MARKER = '# TmuxHub Codex notification bridge v1'
    ROOT = os.path.expanduser('~/.local/share/tmuxhub/codex-notifications')
    if globals().get('__file__') and os.path.basename(__file__) == 'bridge.py':
        ROOT = os.path.dirname(os.path.abspath(__file__))

    def clean(value, limit=256):
        if not isinstance(value, str):
            return None
        value = ''.join(c for c in value if ord(c) >= 32 and not 127 <= ord(c) <= 159)
        data = value.encode('utf-8')[:limit]
        return data.decode('utf-8', errors='ignore')

    def private_dir(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('unsafe notification directory')
        os.chmod(path, 0o700)

    def read_bytes(path, maximum):
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise ValueError('invalid notification file')
            value = stream.read(maximum + 1)
            if len(value) > maximum:
                raise ValueError('notification file too large')
            return value

    def atomic_bytes(path, value, mode=0o600):
        fd, temporary = tempfile.mkstemp(prefix='.tmuxhub-', dir=os.path.dirname(path))
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(os.path.dirname(path), os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def atomic_json(path, value):
        atomic_bytes(path, (json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n').encode('utf-8'))

    @contextlib.contextmanager
    def locked(create=False):
        if create:
            private_dir(ROOT)
            private_dir(os.path.join(ROOT, 'events'))
        elif not os.path.isdir(ROOT):
            raise FileNotFoundError('TMUXHUB_NOT_INSTALLED')
        fd = os.open(os.path.join(ROOT, 'lock'), os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('unsafe notification lock')
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('notification feed busy')
                    time.sleep(0.01)
            yield
        finally:
            os.close(fd)

    def state(create=False):
        path = os.path.join(ROOT, 'state.json')
        if not os.path.exists(path):
            if not create:
                raise FileNotFoundError('TMUXHUB_NOT_INSTALLED')
            if event_files():
                raise ValueError('notification state missing; existing events preserved')
            value = {'sourceID': str(uuid.uuid4()), 'latestSequence': 0}
            atomic_json(path, value)
            return value
        value = json.loads(read_bytes(path, 65536))
        if not isinstance(value, dict) or type(value.get('latestSequence')) is not int or value['latestSequence'] < 0:
            raise ValueError('invalid notification state')
        uuid.UUID(value['sourceID'])
        return value

    def event_files():
        directory = os.path.join(ROOT, 'events')
        if not os.path.isdir(directory):
            return []
        return sorted((entry for entry in os.scandir(directory)
                       if re.fullmatch(r'[0-9]{20}-[0-9a-f-]{36}\.json', entry.name)
                       and entry.is_file(follow_symlinks=False)), key=lambda entry: entry.name)

    def retained_event_ids(files=None):
        cutoff = time.time() - MAX_AGE
        return {entry.name[21:-5] for entry in (files if files is not None else event_files())[-MAX_EVENTS:]
                if entry.stat(follow_symlinks=False).st_mtime >= cutoff}

    def load_read_ids(current):
        path = os.path.join(ROOT, 'read-state.json')
        if not os.path.exists(path):
            return set()
        value = json.loads(read_bytes(path, 262144))
        if not isinstance(value, dict) or not isinstance(value.get('readEventIDs'), list) or len(value['readEventIDs']) > 2000:
            raise ValueError('invalid notification read state')
        uuid.UUID(value['sourceID'])
        for identifier in value['readEventIDs']:
            if not isinstance(identifier, str):
                raise ValueError('invalid notification read identifier')
            uuid.UUID(identifier)
        # Reset/reinstalled sources have separate acknowledgment namespaces.
        if value['sourceID'] != current['sourceID']:
            return set()
        return set(value['readEventIDs'])

    def save_read_ids(current, identifiers):
        path = os.path.join(ROOT, 'read-state.json')
        value = {'sourceID': current['sourceID'], 'readEventIDs': sorted(identifiers)}
        encoded = (json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n').encode('utf-8')
        if not os.path.exists(path) or read_bytes(path, 262144) != encoded:
            atomic_bytes(path, encoded)

    def acknowledge(source_id, event_ids):
        if not isinstance(source_id, str) or not isinstance(event_ids, list) or len(event_ids) > 100:
            raise ValueError('invalid notification acknowledgment')
        uuid.UUID(source_id)
        for identifier in event_ids:
            if not isinstance(identifier, str):
                raise ValueError('invalid notification acknowledgment identifier')
            uuid.UUID(identifier)
        with locked():
            current = state()
            if source_id != current['sourceID']:
                raise ValueError('notification source changed; refresh before marking read')
            retained = retained_event_ids()
            identifiers = (load_read_ids(current) | set(event_ids)) & retained
            save_read_ids(current, identifiers)
            return {'sourceID': current['sourceID'], 'acknowledged': True}

    def prune():
        files = event_files()
        cutoff = time.time() - MAX_AGE
        excess = max(0, len(files) - MAX_EVENTS)
        for entry in files[:excess]:
            os.unlink(entry.path)
        # Sequences are written under the same lock, so old files precede fresh
        # ones. Avoid thousands of metadata requests on a shared home filesystem.
        for entry in files[excess:]:
            if entry.stat(follow_symlinks=False).st_mtime >= cutoff:
                break
            os.unlink(entry.path)
        if os.path.exists(os.path.join(ROOT, 'read-state.json')):
            current = state()
            save_read_ids(current, load_read_ids(current) & retained_event_ids())

    def tmux_context():
        raw = os.environ.get('TMUX', '')
        pane = os.environ.get('TMUX_PANE', '')
        if not raw or not re.fullmatch(r'%[0-9]+', pane):
            return {}
        parts = raw.rsplit(',', 2)
        if len(parts) != 3 or not parts[0].startswith('/') or clean(parts[0], 4096) != parts[0]:
            return {}
        fmt = '#{session_name}\t#{session_id}\t#{session_created}\t#{pid}\t#{window_id}\t#{pane_id}\t#{socket_path}'
        try:
            result = subprocess.run(['tmux', '-S', parts[0], 'display-message', '-p', '-t', pane, fmt],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=0.8, check=True)
            if len(result.stdout) > 16384:
                return {}
            fields = result.stdout.decode('utf-8').rstrip('\n').split('\t')
            if len(fields) != 7 or not re.fullmatch(r'\$[0-9]+', fields[1]) or not re.fullmatch(r'@[0-9]+', fields[4]) or fields[5] != pane:
                return {}
            created, pid = int(fields[2]), int(fields[3])
            if created < 0 or pid <= 0 or fields[6] != parts[0]:
                return {}
            return {'tmuxSession': clean(fields[0], 4096), 'tmuxSessionID': fields[1],
                    'tmuxSessionCreated': created, 'tmuxServerPID': pid, 'tmuxWindow': fields[4],
                    'tmuxPane': pane, 'tmuxSocket': clean(fields[6], 4096)}
        except (OSError, ValueError, subprocess.SubprocessError, UnicodeError):
            return {}

    def emit():
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return
        kind = EVENT_NAMES.get(payload.get('hook_event_name'))
        session_id = clean(payload.get('session_id'))
        if kind is None or not session_id:
            return
        hostname = socket.gethostname()
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,255}', hostname):
            return
        cwd = payload.get('cwd')
        if not isinstance(cwd, str) or not cwd.startswith('/') or clean(cwd, 4096) != cwd:
            cwd = ''
        event = {'id': str(uuid.uuid4()), 'kind': kind, 'sessionID': session_id,
                 'turnID': clean(payload.get('turn_id')), 'cwd': cwd, 'hostname': hostname,
                 'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
        event.update(tmux_context())
        with locked():
            current = state()
            current['latestSequence'] += 1
            event['sourceID'] = current['sourceID']
            event['sequence'] = current['latestSequence']
            # Persist the high-water mark first. A crash may leave a harmless
            # sequence gap, but must never reuse an event sequence.
            atomic_json(os.path.join(ROOT, 'state.json'), current)
            name = '%020d-%s.json' % (event['sequence'], event['id'])
            atomic_json(os.path.join(ROOT, 'events', name), event)
            prune()

    def read_feed(after, limit):
        if after < 0 or not 1 <= limit <= 100:
            raise ValueError('invalid notification cursor')
        with locked():
            current = state()
            files = event_files()
            read_ids = load_read_ids(current)
            if read_ids:
                read_ids &= retained_event_ids(files)
            events = []
            has_more = False
            cutoff = time.time() - MAX_AGE
            for entry in files:
                sequence = int(entry.name.split('-', 1)[0])
                if sequence <= after or entry.stat(follow_symlinks=False).st_mtime < cutoff:
                    continue
                if len(events) == limit:
                    has_more = True
                    break
                event = json.loads(read_bytes(entry.path, 16384))
                if event.get('sequence') != sequence or event.get('sourceID') != current['sourceID']:
                    raise ValueError('notification event identity mismatch')
                events.append(event)
            return {'sourceID': current['sourceID'], 'latestSequence': current['latestSequence'],
                    'events': events, 'hasMore': has_more, 'readEventIDs': sorted(read_ids)}

    def install(source, codex_home=None):
        codex_home = os.path.expanduser(codex_home or os.environ.get('CODEX_HOME') or '~/.codex')
        if not os.path.isabs(codex_home):
            raise ValueError('CODEX_HOME must be absolute')
        os.makedirs(codex_home, mode=0o700, exist_ok=True)
        hooks_path = os.path.realpath(os.path.join(codex_home, 'hooks.json'))
        helper_path = os.path.join(ROOT, 'bridge.py')
        with locked(create=True):
            original = read_bytes(hooks_path, MAX_INPUT) if os.path.exists(hooks_path) else None
            document = json.loads(original) if original is not None else {}
            if not isinstance(document, dict):
                raise ValueError('hooks.json must be an object; existing file preserved')
            hooks = document.setdefault('hooks', {})
            if not isinstance(hooks, dict):
                raise ValueError('hooks.json hooks must be an object; existing file preserved')
            command = shlex.quote(sys.executable) + ' ' + shlex.quote(helper_path) + ' emit'
            for name in EVENT_NAMES:
                groups = hooks.get(name, [])
                if not isinstance(groups, list):
                    raise ValueError('invalid hook event list; existing file preserved')
                retained = []
                for group in groups:
                    if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                        raise ValueError('invalid hook group; existing file preserved')
                    handlers = []
                    for handler in group['hooks']:
                        if not isinstance(handler, dict):
                            raise ValueError('invalid hook handler; existing file preserved')
                        owned = False
                        if handler.get('type') == 'command' and isinstance(handler.get('command'), str):
                            try:
                                argv = shlex.split(handler['command'])
                                owned = len(argv) == 3 and argv[1] == helper_path and argv[2] == 'emit'
                            except ValueError:
                                pass
                        if not owned:
                            handlers.append(handler)
                    if handlers or not group['hooks']:
                        retained.append(dict(group, hooks=handlers))
                retained.append({'hooks': [{'type': 'command', 'command': command, 'timeout': 3}]})
                hooks[name] = retained
            if os.path.exists(helper_path):
                previous = read_bytes(helper_path, MAX_INPUT)
                if not previous.startswith(MARKER.encode()):
                    raise ValueError('bridge path occupied by another file')
            current = state(create=True)
            atomic_bytes(helper_path, source)
            rewritten = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
            if rewritten != original:
                latest = read_bytes(hooks_path, MAX_INPUT) if os.path.exists(hooks_path) else None
                if latest != original:
                    raise ValueError('hooks.json changed during setup; retry')
                if original is not None:
                    backup = hooks_path + '.tmuxhub-backup-' + str(uuid.uuid4())
                    atomic_bytes(backup, original)
                atomic_bytes(hooks_path, rewritten)
        note = '已安装通知桥接。请在此主机的 Codex 中打开 /hooks，审阅并信任新增通知钩子；必要时重新启动 Codex。'
        executable = shutil.which('codex')
        if executable:
            try:
                result = subprocess.run([executable, 'features', 'list'], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, timeout=3)
                lines = result.stdout.decode('utf-8', errors='replace').splitlines()
                enabled = any(re.match(r'^hooks\s+\S+\s+true\s*$', line) for line in lines)
                if not enabled:
                    note += ' 当前 CLI 未报告 hooks 已启用。请在此主机运行 codex features enable hooks，然后重新启动 Codex 并在 /hooks 中审阅；若命令不支持，请先升级 CLI。'
            except (OSError, subprocess.SubprocessError):
                note += ' 无法确认 CLI 的 hooks 状态，请在 Codex 中检查 /hooks。'
        else:
            note += ' 当前环境未找到 codex，请确认使用支持 hooks 的 CLI。'
        return {'sourceID': current['sourceID'], 'message': note}

    if __name__ == '__main__':
        action = sys.argv[1] if len(sys.argv) > 1 else 'emit'
        if action == 'emit':
            try:
                emit()
            except Exception:
                pass
            # Notification failures must never approve, reject or block a tool.
            print('{}')
        else:
            try:
                if action == 'install':
                    result = install(base64.b64decode(sys.argv[2], validate=True))
                elif action == 'read':
                    result = read_feed(int(sys.argv[2]), int(sys.argv[3]))
                elif action == 'ack':
                    if len(sys.argv[2]) > 32768:
                        raise ValueError('notification acknowledgment too large')
                    request = json.loads(base64.b64decode(sys.argv[2], validate=True))
                    if not isinstance(request, dict):
                        raise ValueError('invalid notification acknowledgment')
                    result = acknowledge(request.get('sourceID'), request.get('eventIDs'))
                else:
                    raise ValueError('unknown notification action')
                print(json.dumps(result, ensure_ascii=False))
            except FileNotFoundError:
                sys.stderr.write('TMUXHUB_NOT_INSTALLED\n')
                sys.exit(20)
            except Exception as error:
                sys.stderr.write((clean(str(error), 1024) or 'notification bridge failed') + '\n')
                sys.exit(21)
    """#
}
