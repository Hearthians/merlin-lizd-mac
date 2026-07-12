# Codex Runtime Isolation Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every current and future Merlin Codex runtime off the shared Devbox rootfs onto each target's local `/tmp` NVMe while retaining one verified NAS session pool.

**Architecture:** `startup-minimal-nas-agents.sh` installs a small idempotent shell-time initializer. Shells export a local `CODEX_HOME` and `CODEX_SQLITE_HOME`; the initializer creates local mutable state and links only auth, sessions, and skills to NAS. A separate auditable migration controller freezes the four current Codex writers, immediately quarantines the shared runtime behind a read-only guard, preserves forensic evidence, performs a copy-only session merge, and deploys the shell configuration.

**Tech Stack:** Bash/GNU coreutils on Merlin Linux, zsh/bash managed shell blocks, SSH + `mlx worker login`, NFS JSONL session storage, SHA-256 manifests, tmux metadata.

## Global Constraints

- Do not install or configure OpenCode.
- Do not add a Codex command wrapper, distributed session lock, owner registry, or takeover flow.
- Never send `SIGKILL` automatically. A Codex process that survives `SIGTERM` blocks the migration and requires new user approval.
- Never kill tmux servers, pane shells, `code-mode-host`, training processes, or unrelated commands.
- Never overwrite or delete a canonical or legacy session JSONL.
- Never restore a damaged SQLite database into a new runtime.
- After quarantine, automated rollback must keep the guard and quarantine in
  place; reactivating the damaged runtime requires new explicit approval.
- Do not modify Devbox/Worker lifecycle or mounts.
- Never run the full bootstrap on an existing migration target; deploy only the
  reviewed Codex helper and managed shell block.
- Keep every secret out of manifests, command lines, tmux names, and displayed logs.
- Stage and commit only files named by the current task; preserve all unrelated dirty-worktree state.

---

### Task 1: Lock in runtime-isolation behavior with a shell test

**Files:**
- Create: `tests/test-startup-minimal-nas-agents.sh`
- Modify: `startup-minimal-nas-agents.sh`

**Interfaces:**
- Consumes: `TARGET_HOME`, `SHARED_HOME`, `SHARED_AGENT_HOME`, `LIZD_AGENT_RUNTIME_PARENT`, `TARGET_USER`, `INSTALL_SYSTEM_PACKAGES`, and `INSTALL_NODE_TOOLS`.
- Produces: an installed `lizd-codex-runtime-init` helper and managed shell blocks exporting `LIZD_AGENT_RUNTIME_ROOT`, `CODEX_HOME`, `CODEX_SQLITE_HOME`, and `XDG_CACHE_HOME`.

- [ ] **Step 1: Write a failing isolated test**

Create `tests/test-startup-minimal-nas-agents.sh` with a temporary home/NAS/runtime layout and these assertions:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sut="$repo_root/startup-minimal-nas-agents.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home/tiger"
nas="$tmp/nas/lizd"
runtime="$tmp/worker-tmp"
mkdir -p "$home" "$nas/.agent-shared/codex/sessions" \
  "$nas/.agent-shared/codex/skills" "$runtime"
printf '{}\n' >"$nas/.agent-shared/codex/auth.json"
printf '[projects]\n' >"$nas/.agent-shared/codex/config.toml.template"

TARGET_USER="$(id -un)" TARGET_HOME="$home" SHARED_HOME="$nas" \
LIZD_AGENT_RUNTIME_PARENT="$runtime" INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 \
CONFIGURE_CLAUDE_SHARING=0 LIZD_ALLOW_NON_NFS_SHARED_HOME=1 \
"$sut" --install-codex-runtime-only

HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$runtime" \
LIZD_ALLOW_NON_NFS_SHARED_HOME=1 zsh -dfc \
  'source "$HOME/.zshenv"; printf "%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME" "$XDG_CACHE_HOME"' \
  >"$tmp/paths"

grep -Fx "$runtime/lizd-agent-runtime-$(id -un)/codex" "$tmp/paths"
grep -Fx "$runtime/lizd-agent-runtime-$(id -un)/codex-sqlite" "$tmp/paths"
grep -Fx "$runtime/lizd-agent-runtime-$(id -un)/cache" "$tmp/paths"
codex_home="$runtime/lizd-agent-runtime-$(id -un)/codex"
test "$(readlink "$codex_home/auth.json")" = "$nas/.agent-shared/codex/auth.json"
test "$(readlink "$codex_home/sessions")" = "$nas/.agent-shared/codex/sessions"
test "$(readlink "$codex_home/skills")" = "$nas/.agent-shared/codex/skills"
test -f "$codex_home/config.toml"
! grep -Eq '^[[:space:]]*sqlite_home[[:space:]]*=' "$codex_home/config.toml"
test -f "$codex_home/.lizd-runtime-v1"
```

Add a concurrent case that starts eight shells and requires all eight to return zero with one valid config and the same three symlinks.

Add fail-closed cases that require:

- a non-symlink `auth.json`, `sessions`, or `skills` path to remain byte-for-byte
  unchanged while initialization returns nonzero;
- an unavailable/unmounted production NAS root to return nonzero without
  creating a lookalike directory on the underlying filesystem;
- `LIZD_ALLOW_NON_NFS_SHARED_HOME=1` to be required explicitly by synthetic
  tests, never enabled by the installed production shell block.
- a missing NAS auth/session/skills/template target to fail without creating
  any canonical NAS path;
- an inherited shared `CODEX_HOME` to be overridden, and any initializer
  failure to leave both `CODEX_HOME` and `CODEX_SQLITE_HOME` set to
  `/dev/null`.

- [ ] **Step 2: Run the test in isolated Linux temp space and verify RED**

Run `bash -n` locally, then copy only the startup script and test to
`hl_gpu_2:/tmp/lizd-codex-runtime-red-$USER-$(date -u +%Y%m%dT%H%M%SZ)` and
run `bash tests/test-startup-minimal-nas-agents.sh` there with its synthetic
home/NAS/runtime paths.

Expected: FAIL because the current script exports `$HOME/.agent-local/codex` and does not install a shell-time initializer.

- [ ] **Step 3: Implement the minimal runtime initializer**

Add:

```bash
CONFIGURE_CLAUDE_SHARING="${CONFIGURE_CLAUDE_SHARING:-1}"
CODEX_RUNTIME_DIRNAME="${CODEX_RUNTIME_DIRNAME:-lizd-agent-runtime-${TARGET_USER}}"
SHARED_CODEX_CONFIG_TEMPLATE="${SHARED_CODEX_CONFIG_TEMPLATE:-$SHARED_CODEX_HOME/config.toml.template}"
```

Install `$TARGET_HOME/.local/bin/lizd-codex-runtime-init`. It uses `umask 077`, validates required environment variables, acquires a local `mkdir` initialization lock, creates local runtime/cache/SQLite directories, verifies or creates only auth/sessions/skills symlinks, copies the shared config template only when local config is absent, and atomically writes `.lizd-runtime-v1`. A non-symlink path at a required link location is a hard failure and is never deleted.

Expose `--install-codex-runtime-only` as a narrow entry point that installs the
helper and managed Codex block without invoking Claude sharing, history,
package installation, Node tooling, or broad ownership changes. The full main
path may call the same reviewed Codex installer for future new Devboxes.

Before creating any shared path, both the top-level initializer and installed
helper must verify with `findmnt` that production `SHARED_HOME` resolves to
`nfs`/`nfs4`. Synthetic tests may bypass this only with the explicit test flag
above. Remove the existing delete-on-conflict behavior from the Codex path;
copy failures and nonempty conflicts must propagate instead of being ignored.

The `.zshenv` and `.bashrc` managed blocks compute at shell time:

```bash
export LIZD_AGENT_RUNTIME_PARENT="${LIZD_AGENT_RUNTIME_PARENT:-/tmp}"
export LIZD_AGENT_RUNTIME_ROOT="$LIZD_AGENT_RUNTIME_PARENT/lizd-agent-runtime-${USER:-tiger}"
export CODEX_HOME="$LIZD_AGENT_RUNTIME_ROOT/codex"
export CODEX_SQLITE_HOME="$LIZD_AGENT_RUNTIME_ROOT/codex-sqlite"
export XDG_CACHE_HOME="$LIZD_AGENT_RUNTIME_ROOT/cache"
export SHARED_CODEX_HOME="/mnt/bn/vai3d-hl-1/Users/lizd/.agent-shared/codex"
"$HOME/.local/bin/lizd-codex-runtime-init"
```

On helper failure the block exports `CODEX_HOME=/dev/null` and
`CODEX_SQLITE_HOME=/dev/null`. The helper must not create canonical NAS
targets, replace a normal file/directory conflict, or leave temporary config
files behind. Install the managed block with an atomic portable rewrite; do
not use a broad recursive `chown`.

Keep NVM and installed binaries in `LOCAL_STATE_ROOT`. Gate Claude configuration with `CONFIGURE_CLAUDE_SHARING` so migration deployment is Codex-only.

- [ ] **Step 4: Run syntax and behavior tests**

Run `bash -n startup-minimal-nas-agents.sh` locally. Repeat the isolated Linux
test command from Step 2 against a new timestamped `/tmp` directory containing
the updated script and test.

Expected: both exit zero.

- [ ] **Step 5: Commit the runtime initializer**

```bash
git add startup-minimal-nas-agents.sh tests/test-startup-minimal-nas-agents.sh
git commit -m "fix: isolate Codex runtime per Merlin target"
```

---

### Task 2: Build and test the migration controller

**Files:**
- Create: `scripts/migrate-codex-runtime-isolation.sh`
- Create: `tests/test-migrate-codex-runtime-isolation.sh`

**Interfaces:**
- Consumes: exact targets `hl_gpu_2@3960209`, `hl_gpu_2@3959909`, `hl_gpu_2@3966773`, `hl_gpu_2@3966762`; canonical and legacy session roots; the reviewed startup script.
- Produces: phases `preflight`, `freeze`, `quarantine`, `preserve`, `merge`, `deploy`, `verify`, and `rollback`, plus atomic per-phase markers in a timestamped manifest directory.

- [ ] **Step 1: Write failing fixture tests**

Source the missing controller with `MIGRATION_LIBRARY_ONLY=1` and test:

```bash
merge_sessions "$legacy" "$canonical" "$manifest"
test -f "$canonical/2026/07/01/legacy-a.jsonl"
test "$(sha256sum "$canonical/2026/07/01/legacy-a.jsonl" | awk '{print $1}')" = "$legacy_hash"
test -f "$legacy/2026/07/01/legacy-a.jsonl"
```

Also assert that malformed/truncated JSONL fails, the first record must be a
valid `session_meta` UUID, the same UUID with a different hash fails, a
same-basename/different-hash file fails, a changing source fails, quarantine
refuses to run without `freeze.ok`, and static inspection finds no `SIGKILL`,
`kill -9`, legacy-session deletion, canonical overwrite, broad recursive
`chown`, or automatic quarantine restoration.

- [ ] **Step 2: Run the test and verify RED**

Run `bash tests/test-migrate-codex-runtime-isolation.sh`.

Expected: FAIL because the controller does not exist.

- [ ] **Step 3: Implement guarded phases**

Use strict mode, fixed target arrays, `0700` directories, `0600` manifests, and marker files written via temporary file plus atomic rename. Every Worker action emits and the controller validates:

```text
LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id=3966762 status=ok
```

`preflight` records PID, `/proc` start time, executable, tmux pane/shell PID,
cwd, open JSONL paths, and filesystem evidence without prompt content or
persisted arguments. `freeze` revalidates PID identity, sends TERM, waits 20
seconds, and fails if a process remains; two complete no-process/no-old-FD
scans two seconds apart are required. `quarantine` then immediately performs a
same-filesystem atomic rename and installs a `0555` guard with a `0444` README.
`preserve` copies from quarantine into
`/home/tiger/.codex-migrations/<run-id>` after capacity checks. `merge` uses two
identical manifests five seconds apart, validates every JSONL and session UUID,
and performs fsync-backed no-overwrite copies under a NAS migration lock.
`deploy` installs only the reviewed Codex helper/shell block, initializes each
Worker `/tmp`, and reloads a pane only after exact pane/shell/idle checks.
`verify` checks mounts, paths, links, counts, inodes, open FDs, tmux survival,
guard behavior, and warning output. `rollback` never removes merged sessions,
restores damaged runtime state, or removes the guard after quarantine.

- [ ] **Step 4: Run local safety tests**

```bash
bash -n scripts/migrate-codex-runtime-isolation.sh
bash tests/test-migrate-codex-runtime-isolation.sh
! rg -n 'SIGKILL|kill[[:space:]]+-9|rm[[:space:]]+-rf.*sessions' scripts/migrate-codex-runtime-isolation.sh
```

Expected: all exit zero.

- [ ] **Step 5: Repeat fixture tests in isolated Linux temp space on `hl_gpu_2`**

Copy only the controller and tests to
`/tmp/lizd-codex-migration-test-$USER-$(date -u +%Y%m%dT%H%M%SZ)`, run them
against synthetic paths, and remove only that exact test directory after
success.

- [ ] **Step 6: Commit the controller**

```bash
git add scripts/migrate-codex-runtime-isolation.sh tests/test-migrate-codex-runtime-isolation.sh
git commit -m "feat: add guarded Codex runtime migration"
```

---

### Task 3: Freeze a fresh execution plan and run read-only preflight

**Files:**
- Read: `scripts/migrate-codex-runtime-isolation.sh`
- Runtime artifacts only: timestamped local and remote manifests.

**Interfaces:**
- Consumes: live Merlin inventory and exact approved Worker IDs.
- Produces: immutable target/PID/session manifests and a go/no-go verdict.

- [ ] **Step 1: Refresh official inventory and probe exact targets**

Use `merlin-cli cpu-devbox instances list`, `cpu-devbox workers list`, and the `merlin-lizd` controller probe. Never silently substitute a Worker ID.

- [ ] **Step 2: Run controller preflight only**

Report per Worker: transport, Codex PID/start time, tmux pane, cwd, `/tmp` filesystem, shared `.codex` inode, and open DB paths. Report canonical/legacy counts, basename overlap, and SHA-256 manifests.

Expected baseline: four Codex parents, 121 canonical sessions, 25 legacy sessions, zero overlap, and local ext4 `/tmp` on every Worker.

- [ ] **Step 3: Enforce go/no-go gates**

Stop before mutation if a target is unreachable, PID identity is ambiguous, a source session changes, counts drift without explanation, a destination conflict exists, or `/tmp` is not local ext4.

---

### Task 4: Freeze writers, quarantine, preserve evidence, and merge sessions

**Files:** Runtime artifacts only under timestamped manifest/backup directories.

**Interfaces:**
- Consumes: successful immutable preflight.
- Produces: `freeze.ok`, `quarantine.ok`, `preserve.ok`, `merge.ok`, a guarded
  old default path, a preserved runtime, and a 146-file canonical manifest.

- [ ] **Step 1: Run guarded freeze**

Revalidate each exact PID start time and executable, send TERM only to those
four parents, and wait for exit. Scan all four namespaces twice, two seconds
apart, and require no Codex parent/child and no old SQLite/WAL/SHM FD. All tmux
sessions and non-Codex panes must survive. If anything remains, stop for new
approval; do not quarantine or escalate the signal.

- [ ] **Step 2: Immediately quarantine the old shared runtime**

Before any other work can restart Codex, verify the path is a non-symlink
directory, not a mount point, shares a filesystem with its parent, the target
is absent, and no `/proc/*/{fd,cwd,root}` references it. Atomically rename it
to `/home/tiger/.codex.quarantine-<run-id>`, then create the root-owned `0555`
guard and `0444` README at `/home/tiger/.codex`. Recheck no quarantine users.

- [ ] **Step 3: Preserve old runtime**

Capacity-gate `/home/tiger/.codex-migrations/<run-id>`, create it mode `0700`,
and copy from quarantine with `cp -a --reflink=never --sparse=always` without
ignored errors. Save metadata/inventory and hashes of every SQLite/WAL/SHM;
run integrity checks only on backup copies. Re-read hashes and leave the
quarantine unchanged.

- [ ] **Step 4: Merge sessions copy-only**

Acquire a NAS migration lock. Require two full source/destination SHA-256
manifests five seconds apart to match. Validate every JSONL line and initial
`session_meta` UUID; stop on malformed/truncated input or a UUID/hash/path/name
conflict. Copy with destination-local temp files, fsync file, verify, rename
without overwrite, fsync directory, and append `added-files.tsv`. Expected:
25 verified atomic copies, no overwrite, 146 validated canonical sessions,
source count still 25, and matching post-merge manifest.

---

### Task 5: Deploy isolated runtime and verify

**Files:**
- Runtime deployment: reviewed startup script and installed init helper.
- Runtime artifacts: each Worker's `/tmp/lizd-agent-runtime-tiger`.

**Interfaces:**
- Consumes: successful prior phase markers.
- Produces: isolated runtimes and final report while the guard and quarantine
  remain intact.

- [ ] **Step 1: Deploy Codex-only shell/runtime configuration**

Install only the reviewed helper and managed shell blocks on `hl_gpu_2`; do
not invoke the full startup script main path. Initialize each Worker runtime.
Reload a recorded pane only if its pane ID and shell PID still match, its
foreground command is zsh/bash, it has no child, and tmux is not in copy mode.
Otherwise leave it untouched and report why.

- [ ] **Step 2: Verify isolated runtimes**

Each Worker must report:

```text
CODEX_HOME=/tmp/lizd-agent-runtime-tiger/codex
CODEX_SQLITE_HOME=/tmp/lizd-agent-runtime-tiger/codex-sqlite
```

Those paths must be on local NVMe; auth/sessions/skills must resolve to
canonical NAS; all 146 sessions must be visible. Recheck that no process uses
the quarantine and that the old path is still a non-writable guard.

- [ ] **Step 3: Run final non-destructive smoke tests**

Run `codex --version` in each Worker and verify no stale shared-arg0 warning.
Use a disposable invocation that exits without a model request to confirm
mutable files remain local. Run an environment-unset probe and require the
guard to reject writes/recreation. Do not resume prior sessions automatically.

- [ ] **Step 4: Report every target**

Include transport, old PID exit, tmux survival, runtime filesystem, SQLite
path/device/inode, validated session count/hash, warning result, backup path,
quarantine path, guard result, and safe roll-forward recovery command. Overall
success requires every approved reachable target to pass.

---

### Task 6: Final verification and runbook

**Files:**
- Create: `docs/codex-runtime-isolation-runbook.md`
- Modify the approved design only if execution proves a factual correction.

- [ ] **Step 1: Write the runbook from verified commands**

Document layout, canonical sessions, initialization, verification, accepted no-lock convention, backup/quarantine locations, and rollback preconditions without secrets or prompt content.

- [ ] **Step 2: Re-run all checks**

```bash
bash -n startup-minimal-nas-agents.sh
bash -n scripts/migrate-codex-runtime-isolation.sh
bash tests/test-migrate-codex-runtime-isolation.sh
git diff --check
```

Run `tests/test-startup-minimal-nas-agents.sh` again in a fresh isolated Linux
directory on `hl_gpu_2`, then re-run the controller's read-only verify phase
against all four Workers.

- [ ] **Step 3: Commit only the runbook and verified corrections**

```bash
git add docs/codex-runtime-isolation-runbook.md
git commit -m "docs: add Codex runtime isolation runbook"
```
