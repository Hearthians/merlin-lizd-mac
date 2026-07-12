#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MIGRATION_CONTROLLER_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
MIGRATION_MASTER_TARGET='hl_gpu_2'
MIGRATION_WORKER_IDS=(3960209 3959909 3966773 3966762)
readonly MIGRATION_MASTER_TARGET
readonly -a MIGRATION_WORKER_IDS

print_fixed_targets() {
  local worker_id
  printf '%s\n' "$MIGRATION_MASTER_TARGET"
  for worker_id in "${MIGRATION_WORKER_IDS[@]}"; do
    printf '%s@%s\n' "$MIGRATION_MASTER_TARGET" "$worker_id"
  done
}

validate_worker_phase_line() {
  local phase="$1"
  local worker_id="$2"
  local line="$3"
  local approved_worker approved=0

  case "$phase" in
    preflight|freeze|quarantine|preserve|merge|deploy|verify|rollback) ;;
    *)
      printf 'invalid migration phase evidence: %s\n' "$phase" >&2
      return 1
      ;;
  esac
  for approved_worker in "${MIGRATION_WORKER_IDS[@]}"; do
    if [[ "$worker_id" == "$approved_worker" ]]; then
      approved=1
      break
    fi
  done
  if [[ "$approved" != 1 ]]; then
    printf 'unapproved migration Worker evidence: %s\n' "$worker_id" >&2
    return 1
  fi
  [[ "$line" == "LIZD_CODEX_MIGRATION_V1 phase=$phase worker_id=$worker_id status=ok" ]]
}

read_pid_identity() {
  local pid="$1"

  python3 - "$pid" <<'PY'
import os
from pathlib import Path
import sys

try:
    pid = int(sys.argv[1])
except ValueError:
    raise SystemExit("PID must be numeric")
if pid <= 1:
    raise SystemExit("refusing unsafe PID")
stat_text = (Path("/proc") / str(pid) / "stat").read_text(encoding="utf-8")
try:
    remainder = stat_text.rsplit(")", 1)[1].strip().split()
    starttime = int(remainder[19])
except (IndexError, ValueError):
    raise SystemExit(f"could not parse PID identity: {pid}")
executable = os.readlink(Path("/proc") / str(pid) / "exe")
print(f"{starttime}\t{executable}")
PY
}

terminate_recorded_pid() {
  local pid="$1"
  local expected_starttime="$2"
  local expected_executable="$3"
  local timeout_seconds="${MIGRATION_TERM_TIMEOUT_SECONDS:-20}"

  python3 - "$pid" "$expected_starttime" "$expected_executable" "$timeout_seconds" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
expected_starttime = int(sys.argv[2])
expected_executable = sys.argv[3]
timeout_seconds = float(sys.argv[4])
if pid <= 1 or timeout_seconds < 0:
    raise SystemExit("unsafe TERM request")


def identity():
    try:
        stat_text = (Path("/proc") / str(pid) / "stat").read_text(encoding="utf-8")
        remainder = stat_text.rsplit(")", 1)[1].strip().split()
        executable = os.readlink(Path("/proc") / str(pid) / "exe")
        return remainder[0], int(remainder[19]), executable
    except FileNotFoundError:
        return None
    except (IndexError, ValueError):
        raise SystemExit(f"could not parse PID identity: {pid}")


current = identity()
if current is None:
    raise SystemExit(f"recorded PID no longer exists: {pid}")
state, starttime, executable = current
if starttime != expected_starttime:
    raise SystemExit(f"recorded PID start time changed: {pid}")
if executable != expected_executable:
    raise SystemExit(f"recorded PID executable changed: {pid}")
os.kill(pid, signal.SIGTERM)
deadline = time.monotonic() + timeout_seconds
while True:
    current = identity()
    if current is None or current[0] == "Z":
        break
    if current[1] != expected_starttime:
        raise SystemExit(f"PID identity changed while waiting for TERM: {pid}")
    if current[2] != expected_executable:
        raise SystemExit(f"PID executable changed while waiting for TERM: {pid}")
    if time.monotonic() >= deadline:
        raise SystemExit(f"process remained after TERM timeout: {pid}")
    time.sleep(0.1)
PY
}

with_nas_lock() {
  local lock_path="$1"
  shift

  python3 - "$lock_path" "$@" <<'PY'
import fcntl
import os
from pathlib import Path
import subprocess
import sys

lock_path = Path(sys.argv[1])
command = sys.argv[2:]
if not command:
    raise SystemExit("NAS lock requires a command")
lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
with lock_path.open("a+") as lock:
    os.chmod(lock_path, 0o600)
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    completed = subprocess.run(command, check=False)
raise SystemExit(completed.returncode)
PY
}

ensure_secure_directory() {
  local directory="$1"

  python3 - "$directory" <<'PY'
import errno
import os
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
path.mkdir(mode=0o700, parents=True, exist_ok=True)
status = path.lstat()
if not stat.S_ISDIR(status.st_mode) or path.is_symlink():
    raise SystemExit(f"unsafe migration directory: {path}")
os.chmod(path, 0o700)
for target in (path, path.parent):
    descriptor = os.open(target, os.O_RDONLY)
    try:
        try:
            os.fsync(descriptor)
        except OSError as exc:
            if not (sys.platform == "darwin" and exc.errno == errno.EINVAL):
                raise
    finally:
        os.close(descriptor)
PY
}

durable_replace_file() {
  local temporary_path="$1"
  local destination_path="$2"

  python3 - "$temporary_path" "$destination_path" <<'PY'
import errno
import os
from pathlib import Path
import stat
import sys

temporary = Path(sys.argv[1])
destination = Path(sys.argv[2])
status = temporary.lstat()
if not stat.S_ISREG(status.st_mode) or temporary.is_symlink():
    raise SystemExit(f"unsafe temporary manifest: {temporary}")
os.chmod(temporary, 0o600)
descriptor = os.open(temporary, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
if destination.exists() and destination.is_symlink():
    raise SystemExit(f"refusing to replace symlinked manifest: {destination}")
os.replace(temporary, destination)
directory_fd = os.open(destination.parent, os.O_RDONLY)
try:
    try:
        os.fsync(directory_fd)
    except OSError as exc:
        if not (sys.platform == "darwin" and exc.errno == errno.EINVAL):
            raise
finally:
    os.close(directory_fd)
PY
}

write_atomic_text_file() {
  local destination_path="$1"
  local content="$2"

  python3 - "$destination_path" "$content" <<'PY'
import errno
import os
from pathlib import Path
import sys
import tempfile

destination = Path(sys.argv[1])
content = sys.argv[2].encode("utf-8")
descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{destination.name}.tmp.", dir=destination.parent
)
temporary = Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(content):
        offset += os.write(descriptor, content[offset:])
    os.fsync(descriptor)
finally:
    os.close(descriptor)
try:
    if destination.exists() and destination.is_symlink():
        raise RuntimeError(f"refusing to replace symlinked manifest: {destination}")
    os.replace(temporary, destination)
    directory_fd = os.open(destination.parent, os.O_RDONLY)
    try:
        try:
            os.fsync(directory_fd)
        except OSError as exc:
            if not (sys.platform == "darwin" and exc.errno == errno.EINVAL):
                raise
    finally:
        os.close(directory_fd)
except Exception:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
    raise
PY
}

validate_run_id() {
  local run_id="${1:-}"

  if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    printf 'unsafe migration run_id: %s\n' "$run_id" >&2
    return 1
  fi
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
status = path.lstat()
if path.is_symlink() or not stat.S_ISREG(status.st_mode):
    raise SystemExit(f"cannot hash unsafe prerequisite: {path}")
digest = hashlib.sha256()
with path.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

write_merge_marker() {
  local manifest_dir="$1"
  local run_id="$2"
  local prerequisite_manifest="$manifest_dir/merge.prerequisites.sha256"
  local temporary_path prerequisite_path prerequisite_digest

  validate_run_id "$run_id" || return 1
  temporary_path="$(mktemp "$manifest_dir/.merge.prerequisites.sha256.tmp.XXXXXX")" || return 1
  {
    printf 'LIZD_CODEX_PREREQUISITES_V1\tphase=merge\trun_id=%s\n' "$run_id"
    for prerequisite_path in \
      "$manifest_dir/sessions.before-1.tsv" \
      "$manifest_dir/sessions.before-2.tsv" \
      "$manifest_dir/sessions.after.tsv" \
      "$manifest_dir/added-files.tsv"; do
      printf '%s\t%s\n' "$(sha256_file "$prerequisite_path")" \
        "$(basename "$prerequisite_path")"
    done
  } >"$temporary_path" || {
    rm -f "$temporary_path"
    return 1
  }
  durable_replace_file "$temporary_path" "$prerequisite_manifest" || {
    rm -f "$temporary_path"
    return 1
  }
  prerequisite_digest="$(sha256_file "$prerequisite_manifest")" || return 1
  write_atomic_text_file "$manifest_dir/merge.ok" \
    "LIZD_CODEX_MIGRATION_V1 phase=merge run_id=$run_id status=ok prerequisites_sha256=$prerequisite_digest
" || return 1
}

capture_durable_session_manifest() {
  local legacy_root="$1"
  local canonical_root="$2"
  local output_path="$3"
  local run_id="${4:-${MIGRATION_RUN_ID:-}}"
  local temporary_path

  validate_run_id "$run_id" || return 1
  temporary_path="$(mktemp "$(dirname "$output_path")/.$(basename "$output_path").tmp.XXXXXX")" || \
    return 1
  if ! capture_session_manifest "$legacy_root" "$canonical_root" "$temporary_path" \
    "$run_id" "$(basename "$output_path" .tsv)"; then
    rm -f "$temporary_path"
    return 1
  fi
  if ! durable_replace_file "$temporary_path" "$output_path"; then
    rm -f "$temporary_path"
    return 1
  fi
}

publish_session_no_clobber() {
  local source_path="$1"
  local destination_path="$2"
  local journal_path="$3"
  local expected_device="${4:-}"
  local expected_inode="${5:-}"
  local expected_size="${6:-}"
  local expected_mtime_ns="${7:-}"
  local expected_hash="${8:-}"
  local legacy_root="${9:-}"
  local canonical_root="${10:-}"

  python3 - "$source_path" "$destination_path" "$journal_path" \
    "$expected_device" "$expected_inode" "$expected_size" "$expected_mtime_ns" \
    "$expected_hash" "$legacy_root" "$canonical_root" <<'PY'
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
journal = Path(sys.argv[3])
expected_fields = sys.argv[4:9]
legacy_root_arg = sys.argv[9]
canonical_root_arg = sys.argv[10]


def digest_file(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        try:
            os.fsync(descriptor)
        except OSError as exc:
            if not (sys.platform == "darwin" and exc.errno == errno.EINVAL):
                raise
    finally:
        os.close(descriptor)


def require_real_root(root, label):
    status = root.lstat()
    if root.is_symlink() or not stat.S_ISDIR(status.st_mode):
        raise RuntimeError(f"unsafe {label} session root: {root}")


def require_beneath_real_parents(path, root, create_parents=False):
    require_real_root(root, "publish")
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise RuntimeError(f"session path is outside its approved root: {path}")
    if not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
        raise RuntimeError(f"unsafe relative session path: {path}")
    current = root
    for part in relative.parts[:-1]:
        current = current / part
        try:
            current_status = current.lstat()
        except FileNotFoundError:
            if not create_parents:
                raise RuntimeError(f"missing session source parent: {current}")
            current.mkdir(mode=0o700)
            current_status = current.lstat()
        if current.is_symlink() or not stat.S_ISDIR(current_status.st_mode):
            raise RuntimeError(f"symlinked or unsafe session parent: {current}")


if any(expected_fields):
    if not all(expected_fields):
        raise SystemExit("incomplete snapshot-two source identity")
    expected_identity = tuple(map(int, expected_fields[:4]))
    expected_snapshot_hash = expected_fields[4]
    if len(expected_snapshot_hash) != 64 or any(
        character not in "0123456789abcdef" for character in expected_snapshot_hash
    ):
        raise SystemExit("invalid snapshot-two source hash")
else:
    if os.environ.get("MIGRATION_LIBRARY_ONLY") != "1":
        raise SystemExit("production publish requires snapshot-two source identity")
    expected_identity = None
    expected_snapshot_hash = None

if legacy_root_arg:
    require_beneath_real_parents(source, Path(legacy_root_arg))
if canonical_root_arg:
    require_beneath_real_parents(destination, Path(canonical_root_arg), create_parents=True)
else:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
journal.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
temporary_path = None
linked_by_this_attempt = False
recovery_path = None
try:
    source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    source_fd = os.open(source, source_flags)
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError(f"session source is not a regular file: {source}")
        if expected_identity is not None:
            actual_identity = (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
            if actual_identity != expected_identity:
                raise RuntimeError(f"session source changed after snapshot two: {source}")
        temporary_fd, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.tmp.", dir=destination.parent
        )
        temporary_path = Path(temporary_name)
        try:
            os.fchmod(temporary_fd, 0o600)
            digest = hashlib.sha256()
            size = 0
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                os.write(temporary_fd, chunk)
                digest.update(chunk)
                size += len(chunk)
            os.fsync(temporary_fd)
            after = os.fstat(source_fd)
        finally:
            os.close(temporary_fd)
    finally:
        os.close(source_fd)

    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after or size != before.st_size:
        raise RuntimeError(f"session source changed while copying: {source}")

    expected_hash = digest.hexdigest()
    if expected_snapshot_hash is not None and expected_hash != expected_snapshot_hash:
        raise RuntimeError(f"session source hash changed after snapshot two: {source}")
    temporary_hash, temporary_size = digest_file(temporary_path)
    if (temporary_hash, temporary_size) != (expected_hash, size):
        raise RuntimeError(f"temporary session verification failed: {source}")

    published = False
    try:
        os.link(temporary_path, destination)
        published = True
        linked_by_this_attempt = True
        fsync_directory(destination.parent)
    except FileExistsError:
        destination_status = destination.lstat()
        if destination.is_symlink() or not stat.S_ISREG(destination_status.st_mode):
            raise RuntimeError(f"canonical destination is not a regular file: {destination}")
        destination_hash, destination_size = digest_file(destination)
        if (destination_hash, destination_size) != (expected_hash, size):
            raise RuntimeError(f"canonical destination conflict: {destination}")
        matching_recovery_paths = []
        for candidate in destination.parent.glob(f".{destination.name}.tmp.*"):
            candidate_status = candidate.lstat()
            if (
                stat.S_ISREG(candidate_status.st_mode)
                and (candidate_status.st_dev, candidate_status.st_ino)
                == (destination_status.st_dev, destination_status.st_ino)
            ):
                matching_recovery_paths.append(candidate)
        if len(matching_recovery_paths) > 1:
            raise RuntimeError(f"multiple publish recovery links exist: {destination}")
        if matching_recovery_paths:
            recovery_path = matching_recovery_paths[0]
            recovery_hash, recovery_size = digest_file(recovery_path)
            if (recovery_hash, recovery_size) != (expected_hash, size):
                raise RuntimeError(f"publish recovery link verification failed: {destination}")
            published = True

    hook = os.environ.get("MIGRATION_TEST_AFTER_LINK_HOOK")
    if linked_by_this_attempt and os.environ.get("MIGRATION_LIBRARY_ONLY") == "1" and hook:
        subprocess.run([hook, str(destination)], check=True)

    if published:
        journal_line = f"{destination}\t{expected_hash}\t{size}\n".encode()
        journal_fd = os.open(journal, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            fcntl.flock(journal_fd, fcntl.LOCK_EX)
            with os.fdopen(os.dup(journal_fd), "rb") as reader:
                existing = reader.read()
            if journal_line not in existing.splitlines(keepends=True):
                os.write(journal_fd, journal_line)
            os.fsync(journal_fd)
        finally:
            os.close(journal_fd)
        fsync_directory(journal.parent)
    cleanup_paths = [temporary_path]
    if recovery_path is not None and recovery_path != temporary_path:
        cleanup_paths.append(recovery_path)
    for cleanup_path in cleanup_paths:
        if cleanup_path.exists():
            cleanup_path.unlink()
    fsync_directory(destination.parent)
    temporary_path = None
    recovery_path = None
except Exception as exc:
    if temporary_path is not None and not linked_by_this_attempt:
        try:
            temporary_path.unlink()
            fsync_directory(destination.parent)
        except FileNotFoundError:
            pass
    raise SystemExit(str(exc))
PY
}

emit_session_publish_plan() {
  local manifest_path="$1"
  local run_id="${2:-${MIGRATION_RUN_ID:-}}"

  validate_run_id "$run_id" || return 1
  python3 - "$manifest_path" "$run_id" <<'PY'
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
run_id = sys.argv[2]
canonical_uuids = set()
legacy_rows = []
with manifest.open("r", encoding="utf-8") as stream:
    for line_number, line in enumerate(stream, 1):
        if line_number == 1:
            fields = line.rstrip("\n").split(" ")
            if (
                len(fields) != 3
                or fields[0] != "LIZD_CODEX_ARTIFACT_V1"
                or not fields[1].startswith("type=sessions.")
                or fields[2] != f"run_id={run_id}"
            ):
                raise SystemExit(f"invalid session manifest run_id header: {manifest}")
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 9:
            raise SystemExit(f"invalid session manifest row: {manifest}:{line_number}")
        (
            root_name,
            relative_path,
            basename,
            session_id,
            device,
            inode,
            size,
            mtime_ns,
            digest,
        ) = fields
        if root_name == "canonical":
            canonical_uuids.add(session_id)
        elif root_name == "legacy":
            legacy_rows.append((relative_path, session_id))
        else:
            raise SystemExit(f"invalid session manifest root: {manifest}:{line_number}")

for relative_path, session_id in legacy_rows:
    if session_id not in canonical_uuids:
        for line in manifest.read_text(encoding="utf-8").splitlines()[1:]:
            fields = line.split("\t")
            if len(fields) == 9 and fields[0] == "legacy" and fields[1] == relative_path:
                sys.stdout.buffer.write(line.encode("utf-8") + b"\0")
                break
PY
}

capture_session_manifest() {
  local legacy_root="$1"
  local canonical_root="$2"
  local output_path="$3"
  local run_id="${4:-${MIGRATION_RUN_ID:-}}"
  local artifact_type="${5:-sessions}"

  validate_run_id "$run_id" || return 1
  python3 - "$legacy_root" "$canonical_root" "$run_id" "$artifact_type" \
    >"$output_path" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import uuid

legacy_root = Path(sys.argv[1])
canonical_root = Path(sys.argv[2])
run_id = sys.argv[3]
artifact_type = sys.argv[4]


def validate_root(root, label):
    try:
        status = root.lstat()
    except FileNotFoundError:
        raise SystemExit(f"missing {label} session root: {root}")
    if root.is_symlink() or not stat.S_ISDIR(status.st_mode):
        raise SystemExit(f"unsafe {label} session root: {root}")
    return root.resolve(strict=True)


def iter_jsonl(root):
    root_resolved = root.resolve(strict=True)
    for current, directory_names, file_names in os.walk(root, followlinks=False):
        current_path = Path(current)
        for directory_name in directory_names:
            directory = current_path / directory_name
            if directory.is_symlink():
                raise SystemExit(f"symlinked session directory is forbidden: {directory}")
        for file_name in file_names:
            if not file_name.endswith(".jsonl"):
                continue
            path = current_path / file_name
            status = path.lstat()
            if path.is_symlink() or not stat.S_ISREG(status.st_mode):
                raise SystemExit(f"unsafe JSONL entry: {path}")
            try:
                path.resolve(strict=True).relative_to(root_resolved)
            except (OSError, ValueError):
                raise SystemExit(f"JSONL escapes its session root: {path}")
            yield path


def inspect(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                raise SystemExit(f"unsafe JSONL entry: {path}")
            chunks = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        identity_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        )
        identity_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        )
        if identity_before != identity_after:
            raise SystemExit(f"JSONL changed while capturing manifest: {path}")
        data = b"".join(chunks)
        if len(data) != before.st_size:
            raise SystemExit(f"JSONL size changed while capturing manifest: {path}")
        text = data.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"invalid JSONL: {path}: {exc.__class__.__name__}")

    lines = text.splitlines()
    if not lines:
        raise SystemExit(f"invalid JSONL: {path}: no records")
    session_id = None
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            raise SystemExit(f"invalid JSONL: {path}:{line_number}: empty record")
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid JSONL: {path}:{line_number}: {exc.__class__.__name__}")
        if not isinstance(record, dict):
            raise SystemExit(f"invalid JSONL: {path}:{line_number}: record is not an object")
        if line_number == 1 and record.get("type") != "session_meta":
            raise SystemExit(f"invalid JSONL: {path}: first record is not session_meta")
        if line_number == 1:
            payload = record.get("payload")
            session_id = payload.get("id") if isinstance(payload, dict) else None
            try:
                uuid.UUID(session_id)
            except (AttributeError, TypeError, ValueError):
                raise SystemExit(f"invalid JSONL: {path}: session_meta payload.id is not a UUID")
    return session_id, hashlib.sha256(data).hexdigest(), before


seen_uuids = {}
seen_basenames = {}
validate_root(canonical_root, "canonical")
validate_root(legacy_root, "legacy")
print(
    "LIZD_CODEX_ARTIFACT_V1",
    f"type={artifact_type}",
    f"run_id={run_id}",
)
for root_name, root in (("canonical", canonical_root), ("legacy", legacy_root)):
    for path in sorted(iter_jsonl(root)):
        session_id, digest, status = inspect(path)
        previous = seen_uuids.get(session_id)
        if previous is not None and previous != digest:
            raise SystemExit(f"session UUID has conflicting content: {session_id}")
        seen_uuids[session_id] = digest
        previous = seen_basenames.get(path.name)
        if previous is not None and previous != digest:
            raise SystemExit(f"session basename has conflicting content: {path.name}")
        seen_basenames[path.name] = digest
        relative_path = path.relative_to(root).as_posix()
        if any(character in relative_path for character in ("\t", "\n", "\r")):
            raise SystemExit(f"unsupported session path: {path}")
        print(
            root_name,
            relative_path,
            path.name,
            session_id,
            status.st_dev,
            status.st_ino,
            status.st_size,
            status.st_mtime_ns,
            digest,
            sep="\t",
        )
PY
}

validate_completed_merge() {
  local manifest_dir="$1"
  local run_id="$2"
  local required_path prerequisite_manifest prerequisite_digest marker_content
  local recorded_digest recorded_name actual_digest seen_prerequisites='' prerequisite_count=0

  validate_run_id "$run_id" || return 1

  for required_path in \
    "$manifest_dir/sessions.before-1.tsv" \
    "$manifest_dir/sessions.before-2.tsv" \
    "$manifest_dir/sessions.after.tsv" \
    "$manifest_dir/added-files.tsv" \
    "$manifest_dir/merge.prerequisites.sha256" \
    "$manifest_dir/merge.ok"; do
    if [[ ! -f "$required_path" || -L "$required_path" ]]; then
      printf 'merge marker prerequisite is missing or unsafe: %s\n' "$required_path" >&2
      return 1
    fi
  done
  if ! cmp -s "$manifest_dir/sessions.before-1.tsv" "$manifest_dir/sessions.before-2.tsv"; then
    printf 'merge marker stability manifests differ\n' >&2
    return 1
  fi
  prerequisite_manifest="$manifest_dir/merge.prerequisites.sha256"
  if ! IFS= read -r marker_content <"$prerequisite_manifest" || \
    [[ "$marker_content" != "LIZD_CODEX_PREREQUISITES_V1"$'\t'"phase=merge"$'\t'"run_id=$run_id" ]]; then
    printf 'merge prerequisite manifest run_id is invalid\n' >&2
    return 1
  fi
  while IFS=$'\t' read -r recorded_digest recorded_name; do
    [[ -n "$recorded_digest" || -n "$recorded_name" ]] || continue
    case "$recorded_name" in
      sessions.before-1.tsv|sessions.before-2.tsv|sessions.after.tsv|added-files.tsv) ;;
      *)
        printf 'merge prerequisite digest row is invalid\n' >&2
        return 1
        ;;
    esac
    if [[ "$seen_prerequisites" == *"|$recorded_name|"* || \
      ! "$recorded_digest" =~ ^[0-9a-f]{64}$ ]]; then
      printf 'merge prerequisite digest row is invalid\n' >&2
      return 1
    fi
    actual_digest="$(sha256_file "$manifest_dir/$recorded_name")" || return 1
    if [[ "$actual_digest" != "$recorded_digest" ]]; then
      printf 'merge prerequisite digest changed: %s\n' "$recorded_name" >&2
      return 1
    fi
    seen_prerequisites+="|$recorded_name|"
    prerequisite_count=$((prerequisite_count + 1))
  done < <(tail -n +2 "$prerequisite_manifest")
  if [[ "$prerequisite_count" -ne 4 ]]; then
    printf 'merge prerequisite digest set is incomplete\n' >&2
    return 1
  fi
  prerequisite_digest="$(sha256_file "$prerequisite_manifest")" || return 1
  marker_content="$(<"$manifest_dir/merge.ok")"
  if [[ "$marker_content" != \
    "LIZD_CODEX_MIGRATION_V1 phase=merge run_id=$run_id status=ok prerequisites_sha256=$prerequisite_digest" ]]; then
    printf 'merge marker content or run_id is invalid\n' >&2
    return 1
  fi
}

guard_expected_ids() {
  local expected_uid=0
  local expected_gid=0

  if [[ "${MIGRATION_LIBRARY_ONLY:-0}" == 1 && -n "${MIGRATION_TEST_GUARD_OWNER_UID:-}" ]]; then
    expected_uid="$MIGRATION_TEST_GUARD_OWNER_UID"
    expected_gid="${MIGRATION_TEST_GUARD_OWNER_GID:-$(id -g)}"
  fi
  printf '%s %s\n' "$expected_uid" "$expected_gid"
}

prepare_runtime_guard() {
  local ready_guard="$1"
  local expected_uid expected_gid
  read -r expected_uid expected_gid < <(guard_expected_ids)

  python3 - "$ready_guard" "$expected_uid" "$expected_gid" <<'PY'
import ctypes
import errno
import os
from pathlib import Path
import stat
import sys
import uuid

guard = Path(sys.argv[1])
expected_uid = int(sys.argv[2])
expected_gid = int(sys.argv[3])
readme_content = b"Codex runtime is quarantined; this guard must remain read-only.\n"
RENAME_EXCHANGE = 2
AT_FDCWD = -100

if sys.platform != "linux":
    raise SystemExit("runtime guard preparation requires Linux renameat2")

libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit("libc does not expose renameat2")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int


def exchange(left, right):
    result = renameat2(
        AT_FDCWD,
        os.fsencode(left),
        AT_FDCWD,
        os.fsencode(right),
        RENAME_EXCHANGE,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{left} <-> {right}")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


guard.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
probe = guard.parent / f".lizd-rename-exchange-probe-{uuid.uuid4()}"
left = probe / "left"
right = probe / "right"
try:
    probe.mkdir(mode=0o700)
    left.mkdir(mode=0o700)
    right.mkdir(mode=0o700)
    (left / "LEFT").write_bytes(b"left\n")
    (right / "RIGHT").write_bytes(b"right\n")
    exchange(left, right)
    if not (left / "RIGHT").is_file() or not (right / "LEFT").is_file():
        raise RuntimeError("renameat2 exchange probe did not swap both directories")
finally:
    for path in (left / "LEFT", left / "RIGHT", right / "LEFT", right / "RIGHT"):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    for path in (left, right, probe):
        try:
            path.rmdir()
        except FileNotFoundError:
            pass

readme = guard / "README"
if guard.exists() or guard.is_symlink():
    guard_status = guard.lstat()
    if guard.is_symlink() or not stat.S_ISDIR(guard_status.st_mode):
        raise SystemExit(f"ready guard is not a real directory: {guard}")
    if sorted(entry.name for entry in guard.iterdir()) != ["README"]:
        raise SystemExit(f"ready guard contains unexpected entries: {guard}")
    if readme.read_bytes() != readme_content:
        raise SystemExit(f"ready guard README content is invalid: {readme}")
else:
    guard.mkdir(mode=0o700)
    descriptor = os.open(readme, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, readme_content)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

os.chown(readme, expected_uid, expected_gid)
os.chmod(readme, 0o444)
os.chown(guard, expected_uid, expected_gid)
os.chmod(guard, 0o555)
readme_status = readme.lstat()
guard_status = guard.lstat()
if (
    stat.S_IMODE(guard_status.st_mode) != 0o555
    or stat.S_IMODE(readme_status.st_mode) != 0o444
    or (guard_status.st_uid, guard_status.st_gid) != (expected_uid, expected_gid)
    or (readme_status.st_uid, readme_status.st_gid) != (expected_uid, expected_gid)
):
    raise SystemExit(f"ready guard ownership or mode validation failed: {guard}")
descriptor = os.open(readme, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
fsync_directory(guard)
fsync_directory(guard.parent)
PY
}

quarantine_runtime() {
  local runtime_root="$1"
  local ready_guard="$2"
  local quarantine_destination="$3"
  local manifest_dir="$4"
  local expected_uid expected_gid

  if [[ ! -f "$manifest_dir/freeze.ok" ]]; then
    printf 'quarantine requires durable freeze.ok\n' >&2
    return 1
  fi
  if ! grep -Fx 'LIZD_CODEX_MIGRATION_V1 phase=freeze status=ok' \
    "$manifest_dir/freeze.ok" >/dev/null; then
    printf 'quarantine requires a valid freeze.ok marker\n' >&2
    return 1
  fi
  read -r expected_uid expected_gid < <(guard_expected_ids)
  python3 - "$runtime_root" "$ready_guard" "$quarantine_destination" \
    "$expected_uid" "$expected_gid" <<'PY' || return 1
import ctypes
import os
from pathlib import Path
import stat
import subprocess
import sys

runtime = Path(sys.argv[1])
guard = Path(sys.argv[2])
quarantine = Path(sys.argv[3])
expected_uid = int(sys.argv[4])
expected_gid = int(sys.argv[5])
readme_content = b"Codex runtime is quarantined; this guard must remain read-only.\n"
AT_FDCWD = -100
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2

if sys.platform != "linux":
    raise SystemExit("runtime quarantine requires Linux renameat2")

libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit("libc does not expose renameat2")
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int


def rename_with_flags(source, destination, flags):
    result = renameat2(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        flags,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{source} -> {destination}")


def beneath(path, root):
    try:
        Path(path).resolve(strict=False).relative_to(root)
        return True
    except (OSError, ValueError):
        return False


def reject_runtime_users(root):
    root = root.resolve()
    for process in Path("/proc").glob("[0-9]*"):
        for entry_name in ("cwd", "root"):
            entry = process / entry_name
            try:
                target = os.readlink(entry)
            except OSError:
                continue
            if beneath(target, root):
                raise RuntimeError(f"process {process.name} still uses runtime via {entry_name}")
        fd_dir = process / "fd"
        try:
            descriptors = list(fd_dir.iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            if beneath(target.removesuffix(" (deleted)"), root):
                raise RuntimeError(f"process {process.name} still has an fd beneath runtime")


def tree_identity(root):
    rows = []
    paths = [root]
    paths.extend(sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()))
    for path in paths:
        status = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        if stat.S_ISREG(status.st_mode):
            kind = "file"
            link_target = ""
        elif stat.S_ISDIR(status.st_mode):
            kind = "directory"
            link_target = ""
        elif stat.S_ISLNK(status.st_mode):
            kind = "symlink"
            link_target = os.readlink(path)
        else:
            kind = "other"
            link_target = ""
        rows.append(
            (
                relative,
                kind,
                status.st_dev,
                status.st_ino,
                stat.S_IMODE(status.st_mode),
                status.st_size,
                status.st_mtime_ns,
                link_target,
            )
        )
    return rows


runtime_status = runtime.lstat()
if runtime.is_symlink() or not stat.S_ISDIR(runtime_status.st_mode) or os.path.ismount(runtime):
    raise SystemExit(f"runtime is not an exchangeable real directory: {runtime}")
if quarantine.exists() or quarantine.is_symlink():
    raise SystemExit(f"quarantine destination already exists: {quarantine}")
guard_status = guard.lstat()
runtime_identity = (runtime_status.st_dev, runtime_status.st_ino)
guard_identity = (guard_status.st_dev, guard_status.st_ino)
runtime_manifest = tree_identity(runtime)
readme = guard / "README"
readme_status = readme.lstat()
if (
    guard.is_symlink()
    or not stat.S_ISDIR(guard_status.st_mode)
    or stat.S_IMODE(guard_status.st_mode) != 0o555
    or stat.S_IMODE(readme_status.st_mode) != 0o444
    or (guard_status.st_uid, guard_status.st_gid) != (expected_uid, expected_gid)
    or (readme_status.st_uid, readme_status.st_gid) != (expected_uid, expected_gid)
    or readme.read_bytes() != readme_content
):
    raise SystemExit(f"ready guard validation failed: {guard}")

reject_runtime_users(runtime)
rename_with_flags(runtime, guard, RENAME_EXCHANGE)
try:
    hook = os.environ.get("MIGRATION_TEST_AFTER_EXCHANGE_HOOK")
    if os.environ.get("MIGRATION_LIBRARY_ONLY") == "1" and hook:
        subprocess.run([hook, str(quarantine)], check=True)
    try:
        rename_with_flags(guard, quarantine, RENAME_NOREPLACE)
    except Exception as exc:
        runtime_now = runtime.lstat()
        displaced_now = guard.lstat()
        if (runtime_now.st_dev, runtime_now.st_ino) != guard_identity:
            raise SystemExit("guard identity was lost after quarantine rename failure")
        if (displaced_now.st_dev, displaced_now.st_ino) != runtime_identity:
            raise SystemExit("displaced runtime identity was lost after quarantine rename failure")
        if tree_identity(guard) != runtime_manifest:
            raise SystemExit("displaced runtime changed after quarantine rename failure")
        raise SystemExit(
            "quarantine destination appeared after exchange; guard remains active and "
            f"displaced runtime remains at {guard}: {exc}"
        )
finally:
    directory_fd = os.open(runtime.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

runtime_now = runtime.lstat()
quarantine_now = quarantine.lstat()
if (runtime_now.st_dev, runtime_now.st_ino) != guard_identity:
    raise SystemExit("guard identity validation failed after quarantine exchange")
if (quarantine_now.st_dev, quarantine_now.st_ino) != runtime_identity:
    raise SystemExit("runtime identity validation failed after quarantine exchange")
if tree_identity(quarantine) != runtime_manifest:
    raise SystemExit("runtime metadata manifest changed during quarantine exchange")
runtime_readme = runtime / "README"
if (
    stat.S_IMODE(runtime_now.st_mode) != 0o555
    or stat.S_IMODE(runtime_readme.lstat().st_mode) != 0o444
    or runtime_readme.read_bytes() != readme_content
):
    raise SystemExit("runtime guard postcondition failed after quarantine exchange")
reject_runtime_users(quarantine)
PY
  write_atomic_text_file "$manifest_dir/quarantine.ok" \
    'LIZD_CODEX_MIGRATION_V1 phase=quarantine status=ok
' || return 1
}

rollback_after_quarantine() {
  local runtime_guard="$1"
  local quarantine_root="$2"
  local manifest_dir="$3"

  if [[ ! -f "$manifest_dir/quarantine.ok" || -L "$manifest_dir/quarantine.ok" ]]; then
    printf 'post-quarantine rollback requires durable quarantine.ok\n' >&2
    return 1
  fi
  if ! grep -Fx 'LIZD_CODEX_MIGRATION_V1 phase=quarantine status=ok' \
    "$manifest_dir/quarantine.ok" >/dev/null; then
    printf 'post-quarantine rollback requires a valid quarantine.ok marker\n' >&2
    return 1
  fi
  python3 - "$runtime_guard" "$quarantine_root" <<'PY' || return 1
from pathlib import Path
import stat
import sys

guard = Path(sys.argv[1])
quarantine = Path(sys.argv[2])
guard_status = guard.lstat()
quarantine_status = quarantine.lstat()
readme = guard / "README"
readme_status = readme.lstat()
if guard.is_symlink() or not stat.S_ISDIR(guard_status.st_mode):
    raise SystemExit(f"rollback guard is not a real directory: {guard}")
if stat.S_IMODE(guard_status.st_mode) != 0o555:
    raise SystemExit(f"rollback guard is not mode 0555: {guard}")
if readme.is_symlink() or not stat.S_ISREG(readme_status.st_mode):
    raise SystemExit(f"rollback guard README is unsafe: {readme}")
if stat.S_IMODE(readme_status.st_mode) != 0o444:
    raise SystemExit(f"rollback guard README is not mode 0444: {readme}")
if quarantine.is_symlink() or not stat.S_ISDIR(quarantine_status.st_mode):
    raise SystemExit(f"rollback quarantine is not a real directory: {quarantine}")
if (guard_status.st_dev, guard_status.st_ino) == (
    quarantine_status.st_dev,
    quarantine_status.st_ino,
):
    raise SystemExit("rollback guard and quarantine unexpectedly share identity")
PY
  write_atomic_text_file "$manifest_dir/rollback.ok" \
    'LIZD_CODEX_MIGRATION_V1 phase=rollback status=guarded
' || return 1
}

_merge_sessions_locked() {
  local legacy_root="$1"
  local canonical_root="$2"
  local manifest_dir="$3"
  local run_id="$4"
  local source_path destination_path publish_row
  local root_name relative_path basename session_id source_device source_inode
  local source_size source_mtime_ns source_hash
  local first_manifest="$manifest_dir/sessions.before-1.tsv"
  local second_manifest="$manifest_dir/sessions.before-2.tsv"
  local post_manifest="$manifest_dir/sessions.after.tsv"
  local journal_path="$manifest_dir/added-files.tsv"

  ensure_secure_directory "$manifest_dir" || return 1
  if [[ -e "$manifest_dir/merge.ok" ]]; then
    validate_completed_merge "$manifest_dir" "$run_id" || return 1
    return 0
  fi
  capture_durable_session_manifest "$legacy_root" "$canonical_root" "$first_manifest" \
    "$run_id" || return 1
  sleep "${MIGRATION_SETTLE_SECONDS:-5}" || return 1
  capture_durable_session_manifest "$legacy_root" "$canonical_root" "$second_manifest" \
    "$run_id" || return 1
  # The first line identifies each artifact (before-1 vs before-2); compare
  # only the durable session rows for stability.
  if ! diff -q <(tail -n +2 "$first_manifest") \
    <(tail -n +2 "$second_manifest") >/dev/null; then
    printf 'session sources changed during stability window\n' >&2
    return 1
  fi
  if [[ -n "${MIGRATION_TEST_AFTER_SNAPSHOT2_HOOK:-}" ]]; then
    if [[ "${MIGRATION_LIBRARY_ONLY:-0}" != 1 ]]; then
      printf 'snapshot-two test hook is forbidden in production\n' >&2
      return 1
    fi
    "$MIGRATION_TEST_AFTER_SNAPSHOT2_HOOK" "$legacy_root" "$canonical_root" \
      "$manifest_dir" || return 1
  fi
  if [[ ! -e "$journal_path" ]]; then
    write_atomic_text_file "$journal_path" \
      "LIZD_CODEX_ARTIFACT_V1 type=added-files run_id=$run_id
" || return 1
  elif [[ ! -f "$journal_path" || -L "$journal_path" ]]; then
    printf 'unsafe added-files journal: %s\n' "$journal_path" >&2
    return 1
  fi
  while IFS= read -r -d '' publish_row; do
    IFS=$'\t' read -r root_name relative_path basename session_id source_device \
      source_inode source_size source_mtime_ns source_hash <<<"$publish_row"
    if [[ "$root_name" != legacy || -z "$source_hash" ]]; then
      printf 'invalid legacy publish plan row\n' >&2
      return 1
    fi
    source_path="$legacy_root/$relative_path"
    destination_path="$canonical_root/$relative_path"
    publish_session_no_clobber "$source_path" "$destination_path" \
      "$journal_path" "$source_device" "$source_inode" "$source_size" \
      "$source_mtime_ns" "$source_hash" "$legacy_root" "$canonical_root" || return 1
  done < <(emit_session_publish_plan "$second_manifest" "$run_id")
  capture_durable_session_manifest "$legacy_root" "$canonical_root" "$post_manifest" \
    "$run_id" || return 1
  write_merge_marker "$manifest_dir" "$run_id" || return 1
}

merge_sessions() {
  local legacy_root="$1"
  local canonical_root="$2"
  local manifest_dir="$3"
  local run_id="${4:-${MIGRATION_RUN_ID:-}}"
  local lock_path="${MIGRATION_NAS_LOCK_PATH:-$canonical_root/.lizd-codex-migration.lock}"

  validate_run_id "$run_id" || return 1
  python3 - "$legacy_root" "$canonical_root" <<'PY' || return 1
from pathlib import Path
import stat
import sys

for label, raw_path in (("legacy", sys.argv[1]), ("canonical", sys.argv[2])):
    path = Path(raw_path)
    try:
        status = path.lstat()
    except FileNotFoundError:
        raise SystemExit(f"missing {label} session root: {path}")
    if path.is_symlink() or not stat.S_ISDIR(status.st_mode):
        raise SystemExit(f"unsafe {label} session root: {path}")
PY

  with_nas_lock "$lock_path" /bin/bash -c '
    export MIGRATION_LIBRARY_ONLY=1
    export MIGRATION_RUN_ID="$5"
    source "$1"
    _merge_sessions_locked "$2" "$3" "$4" "$5"
  ' lizd-merge "$MIGRATION_CONTROLLER_SOURCE" "$legacy_root" "$canonical_root" "$manifest_dir" \
    "$run_id"
}

usage() {
  printf '%s\n' \
    'Usage: migrate-codex-runtime-isolation.sh --help' \
    'Library-only tested operations: merge quarantine rollback' \
    'Production phase execution is unavailable in this partial controller.'
}

main() {
  if [[ "$#" -eq 0 ]]; then
    usage >&2
    return 64
  fi
  if [[ "$1" == --help && "$#" -eq 1 ]]; then
    usage
    return 0
  fi
  case "$1" in
    merge|quarantine|rollback)
      printf 'default main never executes library-only operation: %s\n' "$1" >&2
      return 69
      ;;
    preflight|freeze|preserve|deploy|verify)
      printf 'production phase is unavailable in this partial controller: %s\n' "$1" >&2
      return 69
      ;;
  esac
  printf 'unsupported or incomplete migration invocation\n' >&2
  usage >&2
  return 64
}

if [[ "${MIGRATION_LIBRARY_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
