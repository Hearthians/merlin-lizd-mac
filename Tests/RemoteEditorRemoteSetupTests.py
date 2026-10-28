#!/usr/bin/env python3
"""Isolated offline setup tests; never touch a real home or SSH connection."""
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile
import textwrap
import unittest


SWIFT = Path(__file__).resolve().parents[1] / 'Sources/TmuxHubCore/RemoteEditorRemoteSetup.swift'
SOURCE = textwrap.dedent(re.search(r'static let script = #"""\n(.*?)\n    """#', SWIFT.read_text(), re.S).group(1)) + '\n'
COMMIT = '1' * 40

INSTALLER = r'''#!/usr/bin/env python3
import json, os, sys
assert '--do-not-sync' in sys.argv
assert '--do-not-include-pack-dependencies' in sys.argv
assert '--start-server' not in sys.argv
directory = sys.argv[sys.argv.index('--extensions-dir') + 1]
os.makedirs(directory, exist_ok=True)
entries = []
for index, value in enumerate(sys.argv):
    if value != '--install-extension':
        continue
    with open(sys.argv[index+1]) as stream:
        package = json.load(stream)
    identifier = package['publisher'] + '.' + package['name']
    relative = identifier + '-' + package['version']
    os.makedirs(os.path.join(directory, relative), exist_ok=True)
    with open(os.path.join(directory, relative, 'package.json'), 'w') as stream:
        json.dump(package, stream)
    entries.append({'identifier': {'id': identifier}, 'relativeLocation': relative,
                    'metadata': {'targetPlatform': 'linux-x64'}})
with open(os.path.join(directory, 'extensions.json'), 'w') as stream:
    json.dump(entries, stream)
'''


class OfflineSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tmuxhub-offline-test-')
        self.home = Path(self.temporary.name)
        self.scope = {'__name__': 'tmuxhub_test'}
        exec(compile(SOURCE, 'remote-editor-setup', 'exec'), self.scope)
        self.root = self.home / '.cache/tmuxhub/remote-editor'
        self.server = self.home / '.vscode-server'
        self.extensions = self.server / 'extensions'
        self.scope.update(ROOT=str(self.root), SERVER=str(self.server), EXTENSIONS=str(self.extensions),
                          target_platform=lambda: 'linux-x64')
        self.scope['private_dir'](str(self.root))

    def tearDown(self):
        self.temporary.cleanup()

    def stage(self):
        return Path(tempfile.mkdtemp(prefix='stage-', dir=str(self.root)))

    def package(self, stage, name='sample.extension', dependencies=None):
        publisher, extension = name.split('.')
        value = dict(publisher=publisher, name=extension, version='1.0.0', extensionDependencies=dependencies or [])
        path = stage / (name + '-1.0.0.vsix')
        path.write_text(json.dumps(value))
        return dict(name=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    def archive(self, stage):
        path = stage / 'server.tar.gz'
        content = INSTALLER.encode()
        with tarfile.open(path, 'w:gz') as archive:
            info = tarfile.TarInfo('vscode-server-linux-x64/bin/code-server')
            info.size, info.mode = len(content), 0o755
            archive.addfile(info, io.BytesIO(content))
        return dict(name=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    def plan(self, stage, files):
        return dict(stage=str(stage), commit=COMMIT, platform='linux-x64', requested=['sample.extension'], files=files)

    def test_python36_syntax_and_platform_validation(self):
        ast.parse(SOURCE, feature_version=(3, 6))
        self.assertIsNone(self.scope['manager'](COMMIT, 'linux-x64'))
        for commit, platform in [('bad', 'linux-x64'), (COMMIT, 'darwin-arm64')]:
            with self.assertRaises(ValueError):
                self.scope['manager'](commit, platform)

    def test_fresh_server_bootstraps_manager_and_installs_without_network(self):
        stage = self.stage()
        package, archive = self.package(stage), self.archive(stage)
        self.scope['install'](self.plan(stage, [package, archive]))
        self.assertFalse(stage.exists())
        self.assertIsNotNone(self.scope['manager'](COMMIT, 'linux-x64'))
        installed = self.scope['installed_extensions']('linux-x64')
        self.assertEqual(self.scope['required_extensions'](['sample.extension'], installed), [])
        self.assertEqual(self.scope['required_extensions'](['other.missing'], installed), ['other.missing'])

    def test_existing_server_is_reused_without_starting_or_terminating_it(self):
        executable = self.server / ('cli/servers/Stable-' + COMMIT + '/server/bin/code-server')
        executable.parent.mkdir(parents=True)
        executable.write_text(INSTALLER)
        executable.chmod(0o700)
        original = executable.stat().st_ino
        stage = self.stage()
        self.scope['install'](self.plan(stage, [self.package(stage)]))
        self.assertEqual(executable.stat().st_ino, original)
        self.assertFalse((self.root / 'managers').exists())

    def test_checksum_mismatch_and_path_escape_never_install(self):
        stage = self.stage()
        package = self.package(stage)
        package['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.scope['install'](self.plan(stage, [package]))
        self.assertFalse(stage.exists())
        self.assertFalse(self.extensions.exists())
        with self.assertRaises(ValueError):
            self.scope['safe_stage'](str(self.home))

    def test_archive_rejects_traversal_and_symlink_parent_escape(self):
        for malicious in ('../escaped', '/tmp/tmuxhub-escaped', 'dir/link/../escaped'):
            archive_path = self.home / 'bad.tar.gz'
            output = self.home / 'extract'
            output.mkdir(exist_ok=True)
            with tarfile.open(archive_path, 'w:gz') as archive:
                link = tarfile.TarInfo('dir/link')
                link.type, link.linkname = tarfile.SYMTYPE, '..'
                archive.addfile(link)
                content = b'bad'
                item = tarfile.TarInfo(malicious)
                item.size = len(content)
                archive.addfile(item, io.BytesIO(content))
            with self.assertRaises(ValueError):
                self.scope['extract_manager'](str(archive_path), str(output))
            self.assertFalse((self.home / 'escaped').exists())

    def test_pack_dependencies_wrong_architecture_and_stale_entries(self):
        folder = self.extensions / 'sample.extension-1.0.0'
        folder.mkdir(parents=True)
        (folder / 'package.json').write_text(json.dumps(dict(publisher='sample', name='extension',
            extensionDependencies=['dep.required'], extensionPack=['pack.required'])))
        entries = [dict(identifier=dict(id='sample.extension'), relativeLocation=folder.name,
                        metadata=dict(targetPlatform='linux-x64')),
                   dict(identifier=dict(id='old.missing'), relativeLocation='old.missing-1.0.0'),
                   dict(identifier=dict(id='escape.path'), relativeLocation='../escape')]
        (self.extensions / 'extensions.json').write_text(json.dumps(entries))
        installed = self.scope['installed_extensions']('linux-x64')
        self.assertEqual(self.scope['required_extensions'](['sample.extension'], installed), ['dep.required', 'pack.required'])
        self.assertEqual(self.scope['installed_extensions']('darwin-arm64'), {})


if __name__ == '__main__':
    unittest.main()
