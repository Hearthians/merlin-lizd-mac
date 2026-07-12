#!/usr/bin/env bash
# Narrow remote companion for the reviewed Codex runtime migration.  It runs
# inside one frozen Worker and never prints environment variables or prompts.
set -Eeuo pipefail
umask 077

phase="${1:?phase is required}"
state_dir="${MIGRATION_STATE_DIR:?MIGRATION_STATE_DIR is required}"
worker_id="${MIGRATION_WORKER_ID:?MIGRATION_WORKER_ID is required}"
controller="${MIGRATION_CONTROLLER_PATH:?MIGRATION_CONTROLLER_PATH is required}"
startup="${MIGRATION_STARTUP_PATH:?MIGRATION_STARTUP_PATH is required}"
target_user="${TARGET_USER:-tiger}"
target_home="${TARGET_HOME:-/home/tiger}"
runtime_root="$target_home/.codex"
preflight_path="$state_dir/worker-$worker_id.preflight.tsv"
runtime_parent="${LIZD_AGENT_RUNTIME_PARENT:-/mnt/local/localcache00/${target_user}-agent-local}"

write_preflight() {
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  python3 - "$preflight_path" "$worker_id" "$runtime_root" <<'PY'
import os
from pathlib import Path
import stat
import tempfile
import sys

destination = Path(sys.argv[1])
worker_id = sys.argv[2]
runtime = Path(sys.argv[3])
rows = []
for proc in sorted(Path('/proc').glob('[0-9]*'), key=lambda p: int(p.name)):
    try:
        exe = os.readlink(proc / 'exe')
        if Path(exe).name != 'codex':
            continue
        stat_text = (proc / 'stat').read_text(encoding='utf-8')
        remainder = stat_text.rsplit(')', 1)[1].strip().split()
        starttime = int(remainder[19])
    except (FileNotFoundError, PermissionError, IndexError, ValueError):
        continue
    rows.append((int(proc.name), starttime, exe))

runtime_status = runtime.lstat()
if runtime.is_symlink() or not stat.S_ISDIR(runtime_status.st_mode):
    raise SystemExit(f'unsafe runtime root: {runtime}')
tmp_fd, tmp_name = tempfile.mkstemp(prefix='.preflight.', dir=destination.parent)
try:
    os.fchmod(tmp_fd, 0o600)
    content = [f'LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id={worker_id} status=ok']
    content.append(f'RUNTIME\t{runtime_status.st_dev}\t{runtime_status.st_ino}\t{stat.S_IMODE(runtime_status.st_mode):o}')
    for pid, starttime, exe in rows:
        content.append(f'PID\t{pid}\t{starttime}\t{exe}')
    os.write(tmp_fd, ('\n'.join(content) + '\n').encode())
    os.fsync(tmp_fd)
finally:
    os.close(tmp_fd)
os.replace(tmp_name, destination)
directory_fd = os.open(destination.parent, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
print(f'LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id={worker_id} status=ok pids={len(rows)}')
PY
  printf 'TMP_FSTYPE=%s\n' "$(findmnt -n -T /tmp -o FSTYPE)"
}

freeze() {
  [[ -f "$preflight_path" && ! -L "$preflight_path" ]] || {
    printf 'missing preflight for Worker %s\n' "$worker_id" >&2
    return 1
  }
  MIGRATION_LIBRARY_ONLY=1 source "$controller"
  local kind pid starttime executable
  while IFS=$'\t' read -r kind pid starttime executable; do
    [[ "$kind" == PID ]] || continue
    terminate_recorded_pid "$pid" "$starttime" "$executable"
  done <"$preflight_path"
  verify_clean
  printf 'LIZD_CODEX_MIGRATION_V1 phase=freeze worker_id=%s status=ok\n' "$worker_id"
}

verify_clean() {
  python3 - "$runtime_root" <<'PY'
import os
from pathlib import Path
import sys

runtime = Path(sys.argv[1]).resolve(strict=True)
problems = []
for proc in Path('/proc').glob('[0-9]*'):
    try:
        exe = os.readlink(proc / 'exe')
        if Path(exe).name == 'codex':
            problems.append(f'live codex pid {proc.name}')
    except (FileNotFoundError, PermissionError):
        continue
    for location in ('cwd', 'root'):
        try:
            target = Path(os.readlink(proc / location).removesuffix(' (deleted)')).resolve(strict=False)
            target.relative_to(runtime)
            problems.append(f'process {proc.name} {location} uses old runtime')
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            pass
    try:
        descriptors = list((proc / 'fd').iterdir())
    except (FileNotFoundError, PermissionError):
        continue
    for descriptor in descriptors:
        try:
            target = Path(os.readlink(descriptor).removesuffix(' (deleted)')).resolve(strict=False)
            target.relative_to(runtime)
            problems.append(f'process {proc.name} fd uses old runtime')
            break
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            pass
if problems:
    raise SystemExit('; '.join(sorted(set(problems))))
PY
}

initialize() {
  LIZD_AGENT_RUNTIME_PARENT="$runtime_parent" TARGET_USER="$target_user" TARGET_HOME="$target_home" \
    CONFIGURE_CLAUDE_SHARING=0 INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 \
    "$startup" --install-codex-runtime-only
  HOME="$target_home" LIZD_AGENT_RUNTIME_PARENT="$runtime_parent" zsh -dfc 'source "$HOME/.zshenv"; test -f "$CODEX_HOME/.lizd-runtime-v1"'
  printf 'LIZD_CODEX_MIGRATION_V1 phase=deploy worker_id=%s status=ok\n' "$worker_id"
}

verify() {
  HOME="$target_home" LIZD_AGENT_RUNTIME_PARENT="$runtime_parent" zsh -dfc '
    set -e
    source "$HOME/.zshenv"
    findmnt -n -T "$CODEX_HOME" -o FSTYPE
    test "$(readlink "$CODEX_HOME/auth.json")" = "/mnt/bn/vai3d-hl-1/Users/lizd/.agent-shared/codex/auth.json"
    test "$(readlink "$CODEX_HOME/sessions")" = "/mnt/bn/vai3d-hl-1/Users/lizd/.agent-shared/codex/sessions"
    test "$(readlink "$CODEX_HOME/skills")" = "/mnt/bn/vai3d-hl-1/Users/lizd/.agent-shared/codex/skills"
    test -f "$CODEX_HOME/.lizd-runtime-v1"
    codex_bin="${commands[codex]:-}"
    if [[ -z "$codex_bin" ]]; then
      codex_bin="$(find "$HOME/.nvm/versions/node" -type f -path "*/bin/codex" -print -quit 2>/dev/null || true)"
    fi
    test -n "$codex_bin" && test -x "$codex_bin"
    "$codex_bin" --version 2>&1
  ' | tail -n 5
  printf 'LIZD_CODEX_MIGRATION_V1 phase=verify worker_id=%s status=ok\n' "$worker_id"
}

case "$phase" in
  preflight) write_preflight ;;
  freeze) freeze ;;
  clean) verify_clean ;;
  initialize) initialize ;;
  verify) verify ;;
  *) printf 'unsupported target phase: %s\n' "$phase" >&2; exit 64 ;;
esac
