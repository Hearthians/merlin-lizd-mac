#!/usr/bin/env python3
"""Isolated SSH authorization tests; never touch real account files or hosts."""

import base64
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hpc-share-access.py"
SPEC = importlib.util.spec_from_file_location("hpc_share_access", str(SCRIPT))
SHARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARE)


class HPCShareAccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key_directory = tempfile.TemporaryDirectory(prefix="hpc-share-test-keys-")
        cls.keys = []
        for index in range(12):
            path = Path(cls.key_directory.name) / ("key-" + str(index))
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True)
            cls.keys.append(SHARE.validate_public_key(path.with_suffix(".pub").read_bytes()))

    @classmethod
    def tearDownClass(cls):
        cls.key_directory.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hpc-share-test-home-")
        self.home = Path(self.temporary.name)
        self.ssh = self.home / ".ssh"
        self.auth = self.ssh / "authorized_keys"

    def tearDown(self):
        self.temporary.cleanup()

    def seed(self, data):
        self.ssh.mkdir(mode=0o700, exist_ok=True)
        self.auth.write_bytes(data)
        self.auth.chmod(0o600)

    def run_action(self, action, name=None, key=None, dry_run=False):
        return SHARE.manage_access(self.home, action, name, key, dry_run)

    def test_add_list_idempotence_revoke(self):
        original = b"# owner's existing keys\r\n" + self.keys[1][0] + b" owner\r\n"
        self.seed(original)
        self.run_action("add", "alice", self.keys[0])
        self.assertTrue(self.auth.read_bytes().startswith(original))
        self.assertEqual(self.run_action("list"), ["alice\t" + SHARE.fingerprint(self.keys[0][1])])
        backups = list(self.ssh.glob("authorized_keys.hpc-share-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.run_action("add", "alice", self.keys[0])
        self.assertEqual(len(list(self.ssh.glob("authorized_keys.hpc-share-backup-*"))), 1)
        self.run_action("revoke", "alice")
        self.assertEqual(self.auth.read_bytes(), original)
        self.run_action("revoke", "alice")
        self.assertEqual(self.run_action("list"), ["No managed keys."])

    def test_missing_final_newline_and_arbitrary_comments(self):
        original = self.keys[1][0] + b" owner's \xff key\rcomment"
        self.seed(original)
        self.run_action("add", "alice", self.keys[0])
        self.assertTrue(self.auth.read_bytes().startswith(original + b"\n"))
        self.run_action("revoke", "alice")
        self.assertEqual(self.auth.read_bytes(), original + b"\n")

    def test_dry_run_and_list_do_not_create_files(self):
        self.assertEqual(self.run_action("list"), ["No managed keys."])
        self.run_action("add", "alice", self.keys[0], dry_run=True)
        self.assertFalse(self.ssh.exists())
        self.seed(b"# original\n")
        self.run_action("add", "alice", self.keys[0], dry_run=True)
        self.assertEqual(list(self.ssh.iterdir()), [self.auth])
        self.assertEqual(self.auth.read_bytes(), b"# original\n")

    def test_rejects_restricted_and_unmanaged_duplicate_keys(self):
        for prefix in (b"", b'from="10.0.0.0/8",command="printf \\\"hi there\\\"" '):
            with self.subTest(prefix=prefix):
                original = prefix + self.keys[0][0] + b" owner's key with an unmatched '\n"
                self.seed(original)
                with self.assertRaises(SHARE.AccessError):
                    self.run_action("add", "alice", self.keys[0])
                self.assertEqual(self.auth.read_bytes(), original)

    def test_name_and_key_collisions(self):
        self.run_action("add", "alice", self.keys[0])
        before = self.auth.read_bytes()
        for name, key in (("alice", self.keys[1]), ("bob", self.keys[0])):
            with self.assertRaises(SHARE.AccessError):
                self.run_action("add", name, key)
        self.assertEqual(self.auth.read_bytes(), before)

    def test_commented_keys_are_never_authorizations(self):
        original = b"  # " + self.keys[0][0] + b" hpc-share-access:alice\n"
        self.seed(original)
        self.assertEqual(self.run_action("list"), ["No managed keys."])
        self.run_action("revoke", "alice")
        self.assertEqual(self.auth.read_bytes(), original)
        self.run_action("add", "alice", self.keys[0])
        self.assertEqual(len(self.run_action("list")), 1)
        self.run_action("revoke", "alice")
        self.assertEqual(self.auth.read_bytes(), original)

    def test_revoke_exact_marker_and_duplicate_warning(self):
        unrelated = self.keys[1][0] + b" notes hpc-share-access:alice\n"
        unmanaged_duplicate = self.keys[0][0] + b" manually-added\n"
        self.run_action("add", "alice", self.keys[0])
        self.auth.write_bytes(self.auth.read_bytes() + unrelated + unmanaged_duplicate)
        result = self.run_action("revoke", "alice")
        self.assertIn("may still allow login", result[0])
        self.assertEqual(self.auth.read_bytes(), unrelated + unmanaged_duplicate)

    def test_rejects_private_multiline_options_and_malformed_keys(self):
        invalid = (
            b"", b"-----BEGIN OPENSSH PRIVATE KEY-----", b"ssh-ed25519 bad",
            self.keys[0][0] + b"\n" + self.keys[1][0],
            b'restrict ' + self.keys[0][0], self.keys[0][0] + b" \x1b[31m",
            b"ssh-rsa " + self.keys[0][0].split()[1],
            b"ssh-ed25519 " + base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519x"),
        )
        for raw in invalid:
            with self.subTest(raw=raw[:60]):
                with self.assertRaises(SHARE.AccessError):
                    SHARE.validate_public_key(raw)

    def test_bad_names_do_not_create_files(self):
        for name in ("../alice", "alice\nssh-rsa", "", "-a", "a" * 65):
            with self.assertRaises(SHARE.AccessError):
                self.run_action("add", name, self.keys[0])
        self.assertFalse(self.ssh.exists())

    def test_refuses_symlinked_ssh_directory(self):
        target = self.home / "elsewhere"
        target.mkdir()
        self.ssh.symlink_to(target, target_is_directory=True)
        with self.assertRaises((SHARE.AccessError, OSError)):
            self.run_action("add", "alice", self.keys[0])
        self.assertEqual(list(target.iterdir()), [])

    def test_refuses_symlink_and_hardlink_authorized_keys(self):
        self.ssh.mkdir()
        target = self.home / "untouched"
        target.write_bytes(b"do not modify")
        self.auth.symlink_to(target)
        with self.assertRaises((SHARE.AccessError, OSError)):
            self.run_action("add", "alice", self.keys[0])
        self.auth.unlink()
        os.link(str(target), str(self.auth))
        with self.assertRaises(SHARE.AccessError):
            self.run_action("add", "alice", self.keys[0])
        self.assertEqual(target.read_bytes(), b"do not modify")

    def test_refuses_symlink_lock(self):
        self.ssh.mkdir()
        target = self.home / "untouched"
        target.write_bytes(b"do not modify")
        (self.ssh / ".hpc-share-access.lock").symlink_to(target)
        with self.assertRaises((SHARE.AccessError, OSError)):
            self.run_action("add", "alice", self.keys[0])
        self.assertEqual(target.read_bytes(), b"do not modify")

    def test_permissions_and_identical_key_permission_repair(self):
        self.run_action("add", "alice", self.keys[0])
        self.ssh.chmod(0o755)
        self.auth.chmod(0o666)
        self.run_action("add", "alice", self.keys[0])
        self.assertEqual(stat.S_IMODE(self.ssh.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.auth.stat().st_mode), 0o600)
        for backup in self.ssh.glob("authorized_keys.hpc-share-backup-*"):
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)

    def test_concurrent_additions_preserve_all_keys(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(self.run_action, "add", "person-" + str(i), key) for i, key in enumerate(self.keys)]
            for future in futures:
                future.result(timeout=20)
        self.assertEqual(len(self.run_action("list")), len(self.keys))


if __name__ == "__main__":
    unittest.main()
