import Foundation

enum RemoteEditorRemoteSetup {
    struct Probe: Decodable {
        let platform: String
        let installed: [String]
        let missing: [String]
        let needsManager: Bool
    }

    static func command(destination: String, action: String, arguments: [String]) throws -> CommandSpec {
        guard IdentifierValidator.isSSHDestination(destination) else { throw RemoteEditorError.invalidDestination }
        let program = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let suffix = try ([action] + arguments).map(AttachmentPaths.shellQuote).joined(separator: " ")
        let remote = "python3 -c " + program + " " + suffix
        return CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", destination, remote,
        ])
    }

    static func encoded<T: Encodable>(_ value: T) throws -> String {
        try JSONEncoder().encode(value).base64EncodedString()
    }

    // Python 3.6 compatible. Work stays in this user's private cache and VS Code
    // extension directory. The script never starts or kills a VS Code server.
    static let script = #"""
    import base64, fcntl, hashlib, json, os, platform, re, shutil, stat, subprocess, sys, tarfile, tempfile, time

    ROOT = os.path.expanduser('~/.cache/tmuxhub/remote-editor')
    SERVER = os.path.expanduser('~/.vscode-server')
    EXTENSIONS = os.path.join(SERVER, 'extensions')
    ID = re.compile(r'^[a-z0-9][a-z0-9_-]*\.[a-z0-9][a-z0-9_-]*$')

    def private_dir(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Unsafe VS Code setup directory')
        os.chmod(path, 0o700)

    def target_platform():
        system = platform.system().lower()
        arch = {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine().lower())
        if system not in ('linux', 'darwin') or arch is None or os.path.exists('/etc/alpine-release'):
            raise ValueError('Automatic extension setup requires Linux/macOS x64 or arm64')
        return system + '-' + arch

    def manager(commit, target):
        if not re.fullmatch(r'[a-f0-9]{40}', commit) or target != target_platform():
            raise ValueError('Invalid VS Code build or platform')
        candidates = [os.path.join(SERVER, 'cli', 'servers', 'Stable-' + commit, 'server', 'bin', 'code-server'),
                      os.path.join(SERVER, 'bin', commit, 'bin', 'code-server')]
        cache = os.path.join(ROOT, 'managers', commit + '-' + target)
        candidates += [os.path.join(cache, 'bin', 'code-server')]
        if os.path.isdir(cache):
            candidates += [os.path.join(cache, name, 'bin', 'code-server') for name in os.listdir(cache)[:8]]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK) and os.stat(path).st_uid == os.getuid():
                return path
        return None

    def installed_extensions(target):
        result = {}
        try:
            with open(os.path.join(EXTENSIONS, 'extensions.json')) as stream:
                entries = json.load(stream)
        except FileNotFoundError:
            return result
        if not isinstance(entries, list) or len(entries) > 4096:
            raise ValueError('Invalid VS Code extension registry')
        for entry in entries:
            name = entry.get('identifier', {}).get('id', '').lower()
            relative = entry.get('relativeLocation', '')
            if not ID.fullmatch(name) or not relative or '/' in relative or '\\' in relative or relative in ('.', '..'):
                continue
            try:
                with open(os.path.join(EXTENSIONS, relative, 'package.json')) as stream:
                    package = json.load(stream)
                actual = (package.get('publisher', '') + '.' + package.get('name', '')).lower()
                installed_target = entry.get('metadata', {}).get('targetPlatform', 'undefined')
                if actual == name and installed_target in ('undefined', 'universal', target, None):
                    result[name] = package
            except (FileNotFoundError, ValueError):
                continue
        return result

    def required_extensions(requested, installed):
        queue, seen, missing = list(requested), set(), []
        while queue:
            name = queue.pop(0).lower()
            if not ID.fullmatch(name) or len(seen) >= 96:
                raise ValueError('Invalid or excessive configured extensions')
            if name in seen:
                continue
            seen.add(name)
            if name not in installed:
                missing.append(name)
            else:
                package = installed[name]
                queue += package.get('extensionDependencies', []) + package.get('extensionPack', [])
        return missing

    def safe_stage(path):
        if os.path.dirname(path) != ROOT or not os.path.basename(path).startswith('stage-'):
            raise ValueError('Invalid setup staging path')
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Unsafe setup staging path')
        return path

    def extract_manager(archive_path, destination):
        # Archives originate at Microsoft's update service. Validate paths and
        # link targets as well, so extraction cannot escape the private cache.
        with tarfile.open(archive_path, 'r:gz') as archive:
            members = archive.getmembers()
            if len(members) > 100000 or sum(m.size for m in members) > 2 * 1024**3:
                raise ValueError('VS Code server archive exceeds limits')
            root = os.path.realpath(destination)
            for member in members:
                path = os.path.abspath(os.path.join(root, member.name))
                if os.path.isabs(member.name) or os.path.commonpath([root, path]) != root:
                    raise ValueError('Unsafe server archive path')
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise ValueError('Unsafe server archive entry')
                if member.issym() or member.islnk():
                    base = os.path.dirname(path) if member.issym() else root
                    link = os.path.abspath(os.path.join(base, member.linkname))
                    if os.path.isabs(member.linkname) or os.path.commonpath([root, link]) != root:
                        raise ValueError('Unsafe server archive link')
                member.mode &= 0o777
            for member in members:
                path = os.path.realpath(os.path.join(root, member.name))
                if os.path.commonpath([root, path]) != root:
                    raise ValueError('Server archive escapes through a link')
                if member.issym() or member.islnk():
                    base = os.path.dirname(path) if member.issym() else root
                    link = os.path.realpath(os.path.join(base, member.linkname))
                    if os.path.commonpath([root, link]) != root:
                        raise ValueError('Server archive link escapes cache')
                archive.extract(member, root)

    def install(plan):
        stage = safe_stage(plan['stage'])
        commit, target = plan['commit'], plan['platform']
        manager(commit, target)  # validate before touching any shared state
        private_dir(ROOT)
        lock_path = os.path.join(ROOT, 'extensions.lock')
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('Unsafe VS Code installation lock')
            deadline = time.monotonic() + 60
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Another device is preparing VS Code; retry shortly')
                    time.sleep(0.1)
            files = plan['files']
            if len(files) > 97:
                raise ValueError('Too many setup packages')
            for item in files:
                name = item['name']
                if not re.fullmatch(r'[A-Za-z0-9._-]+\.(vsix|tar\.gz)', name):
                    raise ValueError('Invalid package filename')
                path = os.path.join(stage, name)
                info = os.lstat(path)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 512 * 1024**2:
                    raise ValueError('Unsafe setup package')
                digest = hashlib.sha256()
                with open(path, 'rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
                if digest.hexdigest() != item['sha256']:
                    raise ValueError('Setup package checksum mismatch')
            executable = manager(commit, target)
            if executable is None:
                archive = next((item for item in files if item['name'] == 'server.tar.gz'), None)
                if archive is None:
                    raise ValueError('Missing offline extension installer')
                parent = os.path.join(ROOT, 'managers')
                private_dir(parent)
                temporary = tempfile.mkdtemp(prefix='.manager-', dir=parent)
                try:
                    extract_manager(os.path.join(stage, archive['name']), temporary)
                    candidates = [os.path.join(temporary, 'bin', 'code-server')]
                    candidates += [os.path.join(temporary, name, 'bin', 'code-server') for name in os.listdir(temporary)[:8]]
                    if not any(os.path.isfile(path) and os.access(path, os.X_OK) for path in candidates):
                        raise ValueError('VS Code installer not found in archive')
                    destination = os.path.join(parent, commit + '-' + target)
                    if os.path.lexists(destination):
                        info = os.lstat(destination)
                        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                            raise ValueError('Unsafe cached VS Code installer')
                        shutil.rmtree(destination)
                    os.rename(temporary, destination)
                finally:
                    if os.path.isdir(temporary):
                        shutil.rmtree(temporary)
                executable = manager(commit, target)
                if executable is None:
                    raise ValueError('VS Code installer not found in archive')
            packages = [os.path.join(stage, item['name']) for item in files if item['name'].endswith('.vsix')]
            if packages:
                command = [executable, '--extensions-dir', EXTENSIONS, '--user-data-dir', os.path.join(SERVER, 'data'),
                           '--do-not-sync', '--do-not-include-pack-dependencies']
                for path in packages:
                    command += ['--install-extension', path]
                completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           universal_newlines=True, timeout=240)
                if completed.returncode != 0:
                    raise RuntimeError('VS Code offline extension installation failed: ' + completed.stderr[-1200:])
            missing = required_extensions(plan['requested'], installed_extensions(target))
            if missing:
                raise RuntimeError('Missing required VS Code extensions: ' + ', '.join(missing))
            print('TMUXHUB_VSCODE_READY_V1')
        finally:
            os.close(fd)
            shutil.rmtree(stage)

    def main():
        action = sys.argv[1]
        if action == 'probe':
            commit, requested = sys.argv[2], json.loads(base64.b64decode(sys.argv[3]))
            target = target_platform()
            installed = installed_extensions(target)
            print(json.dumps(dict(platform=target, installed=sorted(installed),
                                  missing=required_extensions(requested, installed), needsManager=manager(commit, target) is None)))
        elif action == 'stage':
            private_dir(ROOT)
            print(tempfile.mkdtemp(prefix='stage-', dir=ROOT))
        elif action == 'install':
            install(json.loads(base64.b64decode(sys.argv[2])))
        elif action == 'cleanup':
            shutil.rmtree(safe_stage(sys.argv[2]))
        else:
            raise ValueError('Unknown setup action')

    if __name__ == '__main__':
        try:
            main()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
    """#
}
