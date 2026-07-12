# Codex runtime isolation: active run record

Run ID: `codex-runtime-20260712T165330Z`

Date: 2026-07-13
Scope: `hl_gpu_2`, Workers L40 `3959909`, L20 `3966773`, H20 `3966762`.

CPU Worker `3960209` had already been reclaimed by Merlin and was not retried
or changed.

## Completed safely

- Refreshed the Worker inventory and completed two no-process/no-old-runtime
  scans after terminating only the three recorded Codex executable PIDs with
  `TERM`. No `SIGKILL` was sent.
- Atomically exchanged `/home/tiger/.codex` for a root-owned `0555` guard.
  The prior runtime is at
  `/home/tiger/.codex.quarantine-codex-runtime-20260712T165330Z`; a second
  metadata-preserving backup is under
  `/home/tiger/.codex-migrations/codex-runtime-20260712T165330Z/backup`.
- Created canonical NAS `config.toml.template` from the quarantined config
  with mode `0600`, omitting `sqlite_home`.
- Installed the Codex-only initializer. Each machine now uses its own
  `/mnt/local/localcache00/tiger-agent-local/lizd-agent-runtime-tiger` local
  `CODEX_HOME`, SQLite root, and cache. Only `auth.json`, `sessions`, and
  `skills` are NAS symlinks.
- Verified on master, L40, L20, and H20: local runtime mount is `ext4`, Codex
  is `0.144.1`, and the temporary-directory helper warning is absent.

## Deliberately stopped item

The guarded session merge made **no writes**. It rejected this pre-existing
canonical session because it is malformed/truncated:

`sessions/2026/06/08/rollout-2026-06-08T21-25-25-019ea768-d204-7be2-8dad-f61e18b0b902.jsonl` (JSON decode error at line 2076).

The 25 legacy session files remain intact and unmerged. Do not delete or
overwrite the malformed file. A later repair must first preserve a byte-for-
byte backup, then explicitly choose between recovering a valid prefix,
quarantining the broken session, or retaining it unchanged and excluding it
from the merge.
