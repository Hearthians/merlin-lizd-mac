#!/usr/bin/env python3
"""Manage named SSH public keys in the current HPC account (Python 3.6+)."""

import argparse
import base64
import binascii
import datetime
import fcntl
import hashlib
import os
from pathlib import Path
import pwd
import re
import socket
import stat
import subprocess
import sys
import tempfile
import uuid


MARKER = b"hpc-share-access:"
AUTH_FILE = "authorized_keys"
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
KEY_TYPES = {
    "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
}
# Only the optional options field needs quote parsing; comments are opaque bytes.
ENTRY_RE = re.compile(
    rb'^(?:(?:[^\s"\\]|\\.|"(?:[^"\\]|\\.)*")+[ \t]+)?'
    rb'(?P<kind>(?:ssh-|ecdsa-|sk-)[^ \t]+)[ \t]+'
    rb'(?P<blob>[A-Za-z0-9+/]+={0,2})(?:[ \t]+(?P<comment>.*))?$'
)


class AccessError(Exception):
    pass


def fingerprint(blob):
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def decode_blob(kind, encoded):
    try:
        blob = base64.b64decode(encoded, validate=True)
        size = int.from_bytes(blob[:4], "big")
        if len(blob) < 4 or blob[4:4 + size] != kind or len(blob) <= 4 + size:
            raise ValueError("Key type does not match its data")
        return blob
    except (ValueError, binascii.Error):
        raise AccessError("Invalid SSH public-key data.")


def validate_public_key(raw):
    if len(raw) > 16384:
        raise AccessError("Public key is too long.")
    lines = raw.strip().splitlines()
    if len(lines) != 1 or any(c < 32 and c != 9 for c in lines[0]) or b"\x7f" in lines[0]:
        raise AccessError("Provide exactly one public-key line, without control characters.")
    fields = lines[0].split(None, 2)
    if len(fields) < 2 or fields[0].decode("ascii", "replace") not in KEY_TYPES:
        raise AccessError("Provide a plain SSH public key, not a private key, certificate, or key options.")
    kind, encoded = fields[:2]
    blob = decode_blob(kind, encoded)
    canonical = kind + b" " + base64.b64encode(blob)
    # OpenSSH validates the entire algorithm-specific key, not just the base64 header.
    with tempfile.NamedTemporaryFile(prefix="hpc-public-key-") as handle:
        handle.write(canonical + b"\n")
        handle.flush()
        try:
            result = subprocess.run(
                ["ssh-keygen", "-l", "-E", "sha256", "-f", handle.name],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
            )
        except FileNotFoundError:
            raise AccessError("ssh-keygen is required; install the OpenSSH client tools.")
        except subprocess.TimeoutExpired:
            raise AccessError("ssh-keygen validation timed out.")
    if result.returncode != 0:
        raise AccessError("OpenSSH rejected this public key.")
    return canonical, blob


def parse_entry(line):
    line = line.rstrip(b"\r\n").lstrip(b" \t")
    if not line or line.startswith(b"#"):
        return None
    match = ENTRY_RE.fullmatch(line)
    if not match:
        return None
    try:
        blob = decode_blob(match["kind"], match["blob"])
    except AccessError:
        return None
    comment = (match["comment"] or b"").strip(b" \t")
    name = None
    if comment.startswith(MARKER):
        candidate = comment[len(MARKER):].decode("ascii", "replace")
        if NAME_RE.fullmatch(candidate):
            name = candidate
    return name, blob


def planned_change(original, action, name, key=None):
    if not NAME_RE.fullmatch(name):
        raise AccessError("Name must be 1-64 ASCII letters/digits, dots, underscores, or hyphens; start with a letter/digit.")
    # Split on LF only: arbitrary bytes in comments must survive unchanged.
    lines = original.split(b"\n")
    lines = [line + b"\n" for line in lines[:-1]] + ([lines[-1]] if lines[-1] else [])
    parsed = [(index, parse_entry(line)) for index, line in enumerate(lines)]
    named = [index for index, entry in parsed if entry and entry[0] == name]
    if action == "revoke":
        if not named:
            return original, "No managed key named {}.".format(name)
        updated = b"".join(line for index, line in enumerate(lines) if index not in named)
        message = "Removed {} ({} managed key entry/entries).".format(name, len(named))
        removed_blobs = {entry[1] for index, entry in parsed if index in named}
        if any(entry and entry[1] in removed_blobs for index, entry in parsed if index not in named):
            message += " The same public key remains in another entry and may still allow login."
        return updated, message
    canonical, blob = key
    duplicates = [entry for _, entry in parsed if entry and entry[1] == blob]
    if named:
        if len(named) == 1 and parse_entry(lines[named[0]])[1] == blob:
            return original, "{} is already authorized: {}".format(name, fingerprint(blob))
        raise AccessError("Name {} already has a different key or multiple entries; inspect it before revoking/replacing.".format(name))
    if duplicates:
        raise AccessError("This key is already present under another name or outside this script; left unchanged (including any restrictions).")
    separator = b"" if not original or original.endswith(b"\n") else b"\n"
    entry = canonical + b" " + MARKER + name.encode("ascii") + b"\n"
    return original + separator + entry, "Authorized {}: {}".format(name, fingerprint(blob))


def verify_file(info, label):
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise AccessError("{} must be a regular, single-link file owned by this account.".format(label))


def read_keys(directory):
    try:
        descriptor = os.open(AUTH_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    except FileNotFoundError:
        return b"", None
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        verify_file(info, AUTH_FILE)
        if info.st_size > 8 * 1024 * 1024:
            raise AccessError("authorized_keys is unexpectedly large; inspect it manually.")
        return handle.read(), info


def signature(info):
    if info is None:
        return None
    return info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size, info.st_mode


def create_file(directory, name, data):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    with os.fdopen(descriptor, "wb") as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def replace_keys(directory, original, old_info, updated):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    token = uuid.uuid4().hex
    stage = ".hpc-share-access-" + token
    backup = None
    try:
        create_file(directory, stage, updated)
        current, info = read_keys(directory)
        if current != original or signature(info) != signature(old_info):
            raise AccessError("authorized_keys changed during this operation; retry after other edits finish.")
        if old_info is not None:
            backup = "authorized_keys.hpc-share-backup-{}-{}".format(stamp, token)
            create_file(directory, backup, original)
        os.replace(stage, AUTH_FILE, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(stage, dir_fd=directory)
        except FileNotFoundError:
            pass
    return backup


def manage_access(account_home, action, name=None, key=None, dry_run=False):
    """The home argument also lets tests use isolated temporary accounts."""
    if action not in ("add", "list", "revoke"):
        raise AccessError("Unknown action.")
    if action != "list" and not NAME_RE.fullmatch(name or ""):
        raise AccessError("Use a 1-64 character label: letters/digits, dots, underscores, or hyphens; start with a letter/digit.")
    ssh_directory = Path(account_home) / ".ssh"
    modifying = action != "list" and not dry_run
    if modifying:
        try:
            ssh_directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
    try:
        directory = os.open(str(ssh_directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if action == "list":
            return ["No managed keys."]
        _, message = planned_change(b"", action, name, key)
        return ["Preview: " + message]
    lock = None
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid():
            raise AccessError(".ssh must be owned by this account.")
        if modifying:
            os.fchmod(directory, 0o700)
            lock = os.open(".hpc-share-access.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
            verify_file(os.fstat(lock), "Lock file")
            os.fchmod(lock, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
        original, old_info = read_keys(directory)
        if action == "list":
            rows = []
            for line in original.split(b"\n"):
                entry = parse_entry(line)
                if entry and entry[0]:
                    rows.append("{}\t{}".format(entry[0], fingerprint(entry[1])))
            return rows or ["No managed keys."]
        updated, message = planned_change(original, action, name, key)
        if dry_run:
            return ["Preview: " + message]
        if updated == original and (action != "add" or old_info is None or stat.S_IMODE(old_info.st_mode) == 0o600):
            return [message]
        backup = replace_keys(directory, original, old_info, updated)
        rows = [message]
        if backup:
            rows.append("Backup: " + str(ssh_directory / backup))
        return rows
    finally:
        if lock is not None:
            os.close(lock)
        os.close(directory)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action")
    add = commands.add_parser("add", help="Authorize one person's public key")
    add.add_argument("name", help="A unique label such as alice-laptop")
    source = add.add_mutually_exclusive_group(required=True)
    source.add_argument("--key", help="One quoted OpenSSH public-key line")
    source.add_argument("--key-file", help="Public-key file (.pub), or - for standard input")
    add.add_argument("--dry-run", action="store_true", help="Preview without changing any account files")
    commands.add_parser("list", help="List keys managed by this script")
    revoke = commands.add_parser("revoke", help="Remove only the entry with this name")
    revoke.add_argument("name")
    revoke.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if not args.action:
        parser.print_help()
        return 2
    try:
        if os.getuid() == 0 or os.geteuid() != os.getuid():
            raise AccessError("Run as the HPC account owner, without sudo or root.")
        account = pwd.getpwuid(os.getuid())
        key = None
        if args.action == "add":
            if args.key is not None:
                raw = args.key.encode("utf-8")
            elif args.key_file == "-":
                raw = sys.stdin.buffer.read(16385)
            else:
                with open(os.path.expanduser(args.key_file), "rb") as handle:
                    raw = handle.read(16385)
            key = validate_public_key(raw)
        rows = manage_access(account.pw_dir, args.action, getattr(args, "name", None), key, getattr(args, "dry_run", False))
        print("Account: {} @ {}".format(account.pw_name, socket.gethostname()))
        for row in rows:
            print(row)
        if args.action == "add" and not args.dry_run:
            print("Test from the recipient's computer: ssh -i <their-private-key> {}@<reachable-HPC-host>".format(account.pw_name))
        if args.action == "revoke" and not args.dry_run:
            print("Existing SSH sessions remain connected; only this named authorization was removed.")
        return 0
    except (AccessError, OSError) as error:
        print("Error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
