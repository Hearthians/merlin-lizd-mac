#!/usr/bin/env python3
"""Create a no-clobber NAS Codex config template from quarantined local state."""
import errno
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

if len(sys.argv) != 3:
    raise SystemExit("usage: create-codex-config-template.py SOURCE DESTINATION")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
source_status = source.lstat()
if source.is_symlink() or not stat.S_ISREG(source_status.st_mode):
    raise SystemExit(f"unsafe source config: {source}")
if destination.exists() or destination.is_symlink():
    raise SystemExit(f"refusing to overwrite existing config template: {destination}")
if destination.parent.is_symlink() or not destination.parent.is_dir():
    raise SystemExit(f"unsafe config template parent: {destination.parent}")

content = source.read_text(encoding="utf-8")
sqlite_key = re.compile(r"^\s*(sqlite_home|['\"]sqlite_home['\"])\s*=", re.MULTILINE)
if sqlite_key.search(content):
    raise SystemExit("quarantined config contains sqlite_home; manual review required")

fd, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.tmp.", dir=destination.parent)
temporary = Path(temporary_name)
try:
    os.fchmod(fd, 0o600)
    data = content.encode("utf-8")
    written = 0
    while written < len(data):
        written += os.write(fd, data[written:])
    os.fsync(fd)
finally:
    os.close(fd)
try:
    os.link(temporary, destination)
except FileExistsError:
    raise SystemExit(f"config template appeared concurrently: {destination}")
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
directory_fd = os.open(destination.parent, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
print(f"created {destination}")
