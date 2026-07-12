#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sut="$repo_root/scripts/migrate-codex-runtime-isolation.sh"
tmp="$(mktemp -d)"
test_sleep_pid=''

cleanup() {
  if [[ -n "$test_sleep_pid" ]] && kill -0 "$test_sleep_pid" 2>/dev/null; then
    kill -TERM "$test_sleep_pid" 2>/dev/null || true
    wait "$test_sleep_pid" 2>/dev/null || true
  fi
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

legacy="$tmp/legacy"
canonical="$tmp/canonical"
manifest="$tmp/manifest"
mkdir -p "$legacy/2026/07/01" "$canonical" "$manifest"
printf '%s\n' \
  '{"timestamp":"2026-07-01T00:00:00Z","type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111"}}' \
  '{"timestamp":"2026-07-01T00:00:01Z","type":"response_item","payload":{"type":"message"}}' \
  >"$legacy/2026/07/01/legacy-a.jsonl"
legacy_hash="$(hash_file "$legacy/2026/07/01/legacy-a.jsonl")"

export MIGRATION_LIBRARY_ONLY=1
export MIGRATION_SETTLE_SECONDS=0
export MIGRATION_RUN_ID=run-fixture-20260713T000000Z
test -r "$sut" || die "migration controller does not exist: $sut"
source "$sut" || die "migration controller could not be loaded"
merge_sessions "$legacy" "$canonical" "$manifest"

test -f "$canonical/2026/07/01/legacy-a.jsonl" || die "valid legacy session was not merged"
test "$(hash_file "$canonical/2026/07/01/legacy-a.jsonl")" = "$legacy_hash" || \
  die "merged legacy session hash changed"
test -f "$legacy/2026/07/01/legacy-a.jsonl" || die "legacy source was removed"

malformed_legacy="$tmp/malformed-legacy"
malformed_canonical="$tmp/malformed-canonical"
malformed_manifest="$tmp/malformed-manifest"
mkdir -p "$malformed_legacy/2026/07/02" "$malformed_canonical" "$malformed_manifest"
printf '%s\n%s' \
  '{"type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222"}}' \
  '{"type":"response_item"' \
  >"$malformed_legacy/2026/07/02/truncated.jsonl"
if merge_sessions "$malformed_legacy" "$malformed_canonical" "$malformed_manifest" \
  >"$tmp/malformed.out" 2>"$tmp/malformed.err"; then
  die "malformed JSONL was accepted"
fi
test ! -e "$malformed_canonical/2026/07/02/truncated.jsonl" || \
  die "malformed JSONL was published"

wrong_first_legacy="$tmp/wrong-first-legacy"
wrong_first_canonical="$tmp/wrong-first-canonical"
wrong_first_manifest="$tmp/wrong-first-manifest"
mkdir -p "$wrong_first_legacy/2026/07/03" "$wrong_first_canonical" "$wrong_first_manifest"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message"}}' \
  '{"type":"session_meta","payload":{"id":"33333333-3333-4333-8333-333333333333"}}' \
  >"$wrong_first_legacy/2026/07/03/wrong-first.jsonl"
if merge_sessions "$wrong_first_legacy" "$wrong_first_canonical" "$wrong_first_manifest" \
  >"$tmp/wrong-first.out" 2>"$tmp/wrong-first.err"; then
  die "JSONL without session_meta as its first record was accepted"
fi
test ! -e "$wrong_first_canonical/2026/07/03/wrong-first.jsonl" || \
  die "JSONL without first-record session_meta was published"

bad_uuid_legacy="$tmp/bad-uuid-legacy"
bad_uuid_canonical="$tmp/bad-uuid-canonical"
bad_uuid_manifest="$tmp/bad-uuid-manifest"
mkdir -p "$bad_uuid_legacy/2026/07/04" "$bad_uuid_canonical" "$bad_uuid_manifest"
printf '%s\n' '{"type":"session_meta","payload":{"id":"not-a-session-uuid"}}' \
  >"$bad_uuid_legacy/2026/07/04/bad-uuid.jsonl"
if merge_sessions "$bad_uuid_legacy" "$bad_uuid_canonical" "$bad_uuid_manifest" \
  >"$tmp/bad-uuid.out" 2>"$tmp/bad-uuid.err"; then
  die "session_meta with an invalid UUID was accepted"
fi
test ! -e "$bad_uuid_canonical/2026/07/04/bad-uuid.jsonl" || \
  die "session_meta with an invalid UUID was published"

uuid_conflict_legacy="$tmp/uuid-conflict-legacy"
uuid_conflict_canonical="$tmp/uuid-conflict-canonical"
uuid_conflict_manifest="$tmp/uuid-conflict-manifest"
mkdir -p "$uuid_conflict_legacy/2026/07/05" \
  "$uuid_conflict_canonical/2026/06/30" "$uuid_conflict_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"44444444-4444-4444-8444-444444444444"}}' \
  '{"type":"response_item","payload":{"value":"canonical"}}' \
  >"$uuid_conflict_canonical/2026/06/30/canonical.jsonl"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"44444444-4444-4444-8444-444444444444"}}' \
  '{"type":"response_item","payload":{"value":"legacy"}}' \
  >"$uuid_conflict_legacy/2026/07/05/legacy.jsonl"
if merge_sessions "$uuid_conflict_legacy" "$uuid_conflict_canonical" "$uuid_conflict_manifest" \
  >"$tmp/uuid-conflict.out" 2>"$tmp/uuid-conflict.err"; then
  die "same session UUID with a different hash was accepted"
fi
test ! -e "$uuid_conflict_canonical/2026/07/05/legacy.jsonl" || \
  die "session UUID conflict was published"

basename_conflict_legacy="$tmp/basename-conflict-legacy"
basename_conflict_canonical="$tmp/basename-conflict-canonical"
basename_conflict_manifest="$tmp/basename-conflict-manifest"
mkdir -p "$basename_conflict_legacy/2026/07/06" \
  "$basename_conflict_canonical/2026/06/29" "$basename_conflict_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"55555555-5555-4555-8555-555555555555"}}' \
  >"$basename_conflict_canonical/2026/06/29/same-name.jsonl"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"66666666-6666-4666-8666-666666666666"}}' \
  >"$basename_conflict_legacy/2026/07/06/same-name.jsonl"
if merge_sessions "$basename_conflict_legacy" "$basename_conflict_canonical" \
  "$basename_conflict_manifest" >"$tmp/basename-conflict.out" 2>"$tmp/basename-conflict.err"; then
  die "same basename with a different hash was accepted"
fi
test ! -e "$basename_conflict_canonical/2026/07/06/same-name.jsonl" || \
  die "basename conflict was published"

changing_legacy="$tmp/changing-legacy"
changing_canonical="$tmp/changing-canonical"
changing_manifest="$tmp/changing-manifest"
mkdir -p "$changing_legacy/2026/07/07" "$changing_canonical" "$changing_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"77777777-7777-4777-8777-777777777777"}}' \
  >"$changing_legacy/2026/07/07/changing.jsonl"
(
  sleep 0.25
  printf '%s\n' '{"type":"response_item","payload":{"value":"changed"}}' \
    >>"$changing_legacy/2026/07/07/changing.jsonl"
) &
changer_pid="$!"
MIGRATION_SETTLE_SECONDS=1
changing_was_accepted=0
if merge_sessions "$changing_legacy" "$changing_canonical" "$changing_manifest" \
  >"$tmp/changing.out" 2>"$tmp/changing.err"; then
  changing_was_accepted=1
fi
wait "$changer_pid"
MIGRATION_SETTLE_SECONDS=0
test "$changing_was_accepted" = 0 || die "a changing session source was accepted"
test ! -e "$changing_canonical/2026/07/07/changing.jsonl" || \
  die "a changing session source was published"

post_snapshot_legacy="$tmp/post-snapshot-legacy"
post_snapshot_canonical="$tmp/post-snapshot-canonical"
post_snapshot_manifest="$tmp/post-snapshot-manifest"
post_snapshot_hook="$tmp/change-after-snapshot-two"
mkdir -p "$post_snapshot_legacy/2026/07/07" "$post_snapshot_canonical" \
  "$post_snapshot_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"70707070-7070-4070-8070-707070707070"}}' \
  >"$post_snapshot_legacy/2026/07/07/post-snapshot.jsonl"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' '\''{"type":"response_item","payload":{"value":"changed-after-snapshot-two"}}'\'' >>"$1/2026/07/07/post-snapshot.jsonl"' \
  >"$post_snapshot_hook"
chmod 700 "$post_snapshot_hook"
export MIGRATION_TEST_AFTER_SNAPSHOT2_HOOK="$post_snapshot_hook"
if merge_sessions "$post_snapshot_legacy" "$post_snapshot_canonical" \
  "$post_snapshot_manifest" >"$tmp/post-snapshot.out" 2>"$tmp/post-snapshot.err"; then
  die "a source changed after snapshot two was accepted"
fi
unset MIGRATION_TEST_AFTER_SNAPSHOT2_HOOK
test ! -e "$post_snapshot_canonical/2026/07/07/post-snapshot.jsonl" || \
  die "a source changed after snapshot two was published"

symlink_source_real="$tmp/symlink-source-real"
symlink_source_root="$tmp/symlink-source-root"
symlink_source_canonical="$tmp/symlink-source-canonical"
symlink_source_manifest="$tmp/symlink-source-manifest"
mkdir -p "$symlink_source_real/2026/07/07" "$symlink_source_canonical" \
  "$symlink_source_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"71717171-7171-4171-8171-717171717171"}}' \
  >"$symlink_source_real/2026/07/07/symlink-source.jsonl"
ln -s "$symlink_source_real" "$symlink_source_root"
if merge_sessions "$symlink_source_root" "$symlink_source_canonical" \
  "$symlink_source_manifest" >"$tmp/symlink-source.out" 2>"$tmp/symlink-source.err"; then
  die "a symlinked legacy session root was accepted"
fi
test ! -e "$symlink_source_canonical/2026/07/07/symlink-source.jsonl" || \
  die "a session beneath a symlinked legacy root was published"

parent_escape_legacy="$tmp/parent-escape-legacy"
parent_escape_canonical="$tmp/parent-escape-canonical"
parent_escape_outside="$tmp/parent-escape-outside"
parent_escape_manifest="$tmp/parent-escape-manifest"
mkdir -p "$parent_escape_legacy/2026/07/07" "$parent_escape_canonical" \
  "$parent_escape_outside" "$parent_escape_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"72727272-7272-4272-8272-727272727272"}}' \
  >"$parent_escape_legacy/2026/07/07/parent-escape.jsonl"
ln -s "$parent_escape_outside" "$parent_escape_canonical/2026"
if merge_sessions "$parent_escape_legacy" "$parent_escape_canonical" \
  "$parent_escape_manifest" >"$tmp/parent-escape.out" 2>"$tmp/parent-escape.err"; then
  die "a symlinked canonical parent escape was accepted"
fi
test ! -e "$parent_escape_outside/07/07/parent-escape.jsonl" || \
  die "canonical publish escaped through a symlinked parent"

quarantine_runtime_root="$tmp/quarantine-runtime"
quarantine_guard="$tmp/quarantine-runtime.guard-ready"
quarantine_destination="$tmp/quarantine-runtime.quarantine-test"
quarantine_manifest="$tmp/quarantine-phase-manifest"
mkdir -p "$quarantine_runtime_root" "$quarantine_guard" "$quarantine_manifest"
printf 'shared mutable state\n' >"$quarantine_runtime_root/state.sqlite"
printf 'migration guard\n' >"$quarantine_guard/README"
declare -F quarantine_runtime >/dev/null || die "quarantine_runtime library function is missing"
if quarantine_runtime "$quarantine_runtime_root" "$quarantine_guard" \
  "$quarantine_destination" "$quarantine_manifest" \
  >"$tmp/quarantine-no-freeze.out" 2>"$tmp/quarantine-no-freeze.err"; then
  die "quarantine ran without freeze.ok"
fi
test -f "$quarantine_runtime_root/state.sqlite" || \
  die "quarantine changed the runtime without freeze.ok"
test -f "$quarantine_guard/README" || die "quarantine changed the guard without freeze.ok"
test ! -e "$quarantine_destination" || \
  die "quarantine destination appeared without freeze.ok"

remote_sentinel="$tmp/remote-sentinel"
printf '%s\n' '#!/usr/bin/env bash' 'printf called >"$MIGRATION_REMOTE_SENTINEL"' \
  >"$remote_sentinel"
chmod 700 "$remote_sentinel"
if MIGRATION_LIBRARY_ONLY=0 MIGRATION_REMOTE_RUNNER="$remote_sentinel" \
  MIGRATION_REMOTE_SENTINEL="$tmp/remote-called" bash "$sut" \
  >"$tmp/no-args.out" 2>"$tmp/no-args.err"; then
  die "controller without arguments returned success"
fi
grep -qi 'usage' "$tmp/no-args.err" "$tmp/no-args.out" || \
  die "controller without arguments did not print usage"
test ! -e "$tmp/remote-called" || die "controller without arguments touched the remote runner"

if MIGRATION_LIBRARY_ONLY=0 MIGRATION_REMOTE_RUNNER="$remote_sentinel" \
  MIGRATION_REMOTE_SENTINEL="$tmp/unavailable-remote-called" bash "$sut" preflight \
  --run-id run-20260712T000000Z --manifest "$tmp/unavailable-manifest" --execute \
  >"$tmp/unavailable.out" 2>"$tmp/unavailable.err"; then
  die "unimplemented preflight phase returned success"
fi
grep -qi 'unavailable' "$tmp/unavailable.err" || \
  die "unimplemented preflight phase was not clearly reported unavailable"
test ! -e "$tmp/unavailable-manifest" || \
  die "unimplemented preflight phase created a manifest"
test ! -e "$tmp/unavailable-remote-called" || \
  die "unimplemented preflight phase touched the remote runner"
if bash "$sut" 2>&1 | grep -E '^Available phases:.*(preflight|freeze|preserve|deploy|verify)' \
  >/dev/null; then
  die "usage advertises an unavailable production phase"
fi
if MIGRATION_LIBRARY_ONLY=0 MIGRATION_REMOTE_RUNNER="$remote_sentinel" \
  MIGRATION_REMOTE_SENTINEL="$tmp/library-only-remote-called" bash "$sut" merge \
  --run-id run-20260712T000000Z --manifest "$tmp/library-only-manifest" --execute \
  >"$tmp/library-only.out" 2>"$tmp/library-only.err"; then
  die "default main executed a library-only merge"
fi
grep -F 'default main never executes library-only operation: merge' \
  "$tmp/library-only.err" >/dev/null || \
  die "default main did not clearly reject a library-only operation"
test ! -e "$tmp/library-only-manifest" || \
  die "default main created a manifest for a library-only operation"
test ! -e "$tmp/library-only-remote-called" || \
  die "default main touched the remote runner for a library-only operation"

publish_source="$tmp/publish-source.jsonl"
publish_destination_dir="$tmp/publish-canonical/2026/07/08"
publish_destination="$publish_destination_dir/concurrent.jsonl"
publish_journal="$tmp/publish-manifest/added-files.tsv"
mkdir -p "$publish_destination_dir" "$(dirname "$publish_journal")"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"88888888-8888-4888-8888-888888888888"}}' \
  >"$publish_source"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"99999999-9999-4999-8999-999999999999"}}' \
  >"$publish_destination"
publish_winner_hash="$(hash_file "$publish_destination")"
declare -F publish_session_no_clobber >/dev/null || \
  die "publish_session_no_clobber library function is missing"
if publish_session_no_clobber "$publish_source" "$publish_destination" "$publish_journal" \
  >"$tmp/publish-conflict.out" 2>"$tmp/publish-conflict.err"; then
  die "concurrent destination conflict was accepted"
fi
test "$(hash_file "$publish_destination")" = "$publish_winner_hash" || \
  die "concurrent destination was overwritten"
if find "$publish_destination_dir" -maxdepth 1 -name '.concurrent.jsonl.tmp.*' -print | grep -q .; then
  die "publish conflict left a temporary file"
fi

crash_source="$tmp/crash-source.jsonl"
crash_destination_dir="$tmp/crash-canonical/2026/07/08"
crash_destination="$crash_destination_dir/recoverable.jsonl"
crash_journal="$tmp/crash-manifest/added-files.tsv"
crash_hook="$tmp/fail-after-link"
mkdir -p "$crash_destination_dir" "$(dirname "$crash_journal")"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}}' \
  >"$crash_source"
printf '%s\n' '#!/usr/bin/env bash' 'exit 73' >"$crash_hook"
chmod 700 "$crash_hook"
export MIGRATION_TEST_AFTER_LINK_HOOK="$crash_hook"
if publish_session_no_clobber "$crash_source" "$crash_destination" "$crash_journal" \
  >"$tmp/crash-publish.out" 2>"$tmp/crash-publish.err"; then
  die "publish ignored a failure after link and before journal"
fi
unset MIGRATION_TEST_AFTER_LINK_HOOK
test -f "$crash_destination" || die "post-link failure lost the published destination"
test ! -s "$crash_journal" || die "post-link failure falsely recorded a durable journal entry"
crash_temp_count="$(find "$crash_destination_dir" -maxdepth 1 \
  -name '.recoverable.jsonl.tmp.*' -type f | wc -l | tr -d ' ')"
test "$crash_temp_count" = 1 || die "post-link failure did not retain one recovery hard link"
publish_session_no_clobber "$crash_source" "$crash_destination" "$crash_journal"
test "$(wc -l <"$crash_journal" | tr -d ' ')" = 1 || \
  die "publish retry did not recover exactly one added-files journal entry"
if find "$crash_destination_dir" -maxdepth 1 -name '.recoverable.jsonl.tmp.*' -print | grep -q .; then
  die "publish retry left a recovery hard link"
fi

orphan_marker_legacy="$tmp/orphan-marker-legacy"
orphan_marker_canonical="$tmp/orphan-marker-canonical"
orphan_marker_manifest="$tmp/orphan-marker-manifest"
mkdir -p "$orphan_marker_legacy/2026/07/09" "$orphan_marker_canonical" \
  "$orphan_marker_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}' \
  >"$orphan_marker_legacy/2026/07/09/orphan-marker.jsonl"
printf '%s\n' 'LIZD_CODEX_MIGRATION_V1 phase=merge status=ok' \
  >"$orphan_marker_manifest/merge.ok"
if merge_sessions "$orphan_marker_legacy" "$orphan_marker_canonical" \
  "$orphan_marker_manifest" >"$tmp/orphan-marker.out" 2>"$tmp/orphan-marker.err"; then
  die "merge trusted a marker whose durable prerequisites were missing"
fi
test ! -e "$orphan_marker_canonical/2026/07/09/orphan-marker.jsonl" || \
  die "merge with an orphan marker published a session"

test "$(mode_of "$manifest")" = 700 || die "merge manifest directory is not mode 0700"
for durable_merge_file in sessions.before-1.tsv sessions.before-2.tsv \
  sessions.after.tsv added-files.tsv merge.ok; do
  test -f "$manifest/$durable_merge_file" || \
    die "durable merge artifact is missing: $durable_merge_file"
  test "$(mode_of "$manifest/$durable_merge_file")" = 600 || \
    die "durable merge artifact is not mode 0600: $durable_merge_file"
done
grep -E '^LIZD_CODEX_MIGRATION_V1 phase=merge run_id=run-fixture-20260713T000000Z status=ok prerequisites_sha256=[0-9a-f]{64}$' \
  "$manifest/merge.ok" >/dev/null || die "merge marker is not bound to run_id and prerequisites"
test -s "$manifest/merge.prerequisites.sha256" || \
  die "merge prerequisite digest manifest is missing"
for run_bound_manifest in sessions.before-1.tsv sessions.before-2.tsv \
  sessions.after.tsv added-files.tsv; do
  head -n 1 "$manifest/$run_bound_manifest" | \
    grep -Fx "LIZD_CODEX_ARTIFACT_V1 type=${run_bound_manifest%.tsv} run_id=$MIGRATION_RUN_ID" \
    >/dev/null || die "durable merge artifact is not bound to run_id: $run_bound_manifest"
done
if find "$manifest" -maxdepth 1 -name '.merge.ok.tmp.*' -print | grep -q .; then
  die "merge left a temporary marker"
fi

printf '%s\n' '# tampered after completion' >>"$manifest/sessions.after.tsv"
if merge_sessions "$legacy" "$canonical" "$manifest" \
  >"$tmp/tampered-completed.out" 2>"$tmp/tampered-completed.err"; then
  die "completed merge marker trusted a tampered cryptographic prerequisite"
fi

dedupe_legacy="$tmp/dedupe-legacy"
dedupe_canonical="$tmp/dedupe-canonical"
dedupe_manifest="$tmp/dedupe-manifest"
mkdir -p "$dedupe_legacy/2026/07/10" "$dedupe_canonical/2026/06/28" "$dedupe_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}}' \
  '{"type":"response_item","payload":{"value":"identical"}}' \
  >"$dedupe_canonical/2026/06/28/canonical-copy.jsonl"
cp "$dedupe_canonical/2026/06/28/canonical-copy.jsonl" \
  "$dedupe_legacy/2026/07/10/legacy-copy.jsonl"
merge_sessions "$dedupe_legacy" "$dedupe_canonical" "$dedupe_manifest"
test ! -e "$dedupe_canonical/2026/07/10/legacy-copy.jsonl" || \
  die "same UUID and hash was duplicated into canonical sessions"
test -z "$(tail -n +2 "$dedupe_manifest/added-files.tsv")" || \
  die "deduplicated session was recorded as an added file"

locked_legacy="$tmp/locked-legacy"
locked_canonical="$tmp/locked-canonical"
locked_manifest="$tmp/locked-manifest"
nas_lock="$tmp/canonical-sessions.migration.lock"
lock_ready="$tmp/nas-lock-ready"
lock_released="$tmp/nas-lock-released"
mkdir -p "$locked_legacy/2026/07/11" "$locked_canonical" "$locked_manifest"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}}' \
  >"$locked_legacy/2026/07/11/locked.jsonl"
python3 - "$nas_lock" "$lock_ready" "$lock_released" <<'PY' &
import fcntl
import os
from pathlib import Path
import sys
import time

lock_path, ready_path, released_path = map(Path, sys.argv[1:])
with lock_path.open("a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    ready_path.write_text("ready\n", encoding="utf-8")
    with ready_path.open("r") as ready:
        os.fsync(ready.fileno())
    time.sleep(2)
Path(released_path).write_text("released\n", encoding="utf-8")
PY
lock_holder_pid="$!"
lock_wait_count=0
while [[ ! -e "$lock_ready" ]]; do
  kill -0 "$lock_holder_pid" 2>/dev/null || die "NAS lock holder exited before becoming ready"
  sleep 0.02
  lock_wait_count=$((lock_wait_count + 1))
  test "$lock_wait_count" -lt 250 || die "timed out waiting for NAS lock holder"
done
MIGRATION_NAS_LOCK_PATH="$nas_lock"
merge_sessions "$locked_legacy" "$locked_canonical" "$locked_manifest"
MIGRATION_NAS_LOCK_PATH=''
lock_was_held=1
test -e "$lock_released" || lock_was_held=0
wait "$lock_holder_pid"
test "$lock_was_held" = 1 || die "merge did not wait for the NAS migration lock"

if [[ "$(uname -s)" == Linux ]]; then
  exchange_parent="$tmp/exchange-fixture"
  exchange_runtime="$exchange_parent/.codex"
  exchange_guard="$exchange_parent/.codex.guard-ready"
  exchange_quarantine="$exchange_parent/.codex.quarantine-fixture"
  exchange_manifest="$exchange_parent/manifest"
  mkdir -p "$exchange_runtime" "$exchange_manifest"
  printf 'opaque old runtime state\n' >"$exchange_runtime/opaque-runtime-entry"
  printf '%s\n' 'LIZD_CODEX_MIGRATION_V1 phase=freeze status=ok' \
    >"$exchange_manifest/freeze.ok"

  export MIGRATION_TEST_GUARD_OWNER_UID="$(id -u)"
  declare -F prepare_runtime_guard >/dev/null || \
    die "prepare_runtime_guard library function is missing"
  prepare_runtime_guard "$exchange_guard"
  test -d "$exchange_guard" || die "ready guard was not created"
  test "$(mode_of "$exchange_guard")" = 555 || die "ready guard is not mode 0555"
  test -f "$exchange_guard/README" || die "ready guard README is missing"
  test "$(mode_of "$exchange_guard/README")" = 444 || \
    die "ready guard README is not mode 0444"
  test "$(stat -c '%u' "$exchange_guard")" = "$(id -u)" || \
    die "ready guard owner is invalid"

  quarantine_runtime "$exchange_runtime" "$exchange_guard" \
    "$exchange_quarantine" "$exchange_manifest"
  test -f "$exchange_runtime/README" || die "guard did not land at the runtime path"
  test "$(mode_of "$exchange_runtime")" = 555 || \
    die "runtime guard lost mode 0555 after exchange"
  test -f "$exchange_quarantine/opaque-runtime-entry" || \
    die "old runtime did not land in quarantine"
  test ! -e "$exchange_guard" || die "ready guard sibling remained after quarantine rename"
  test -f "$exchange_manifest/quarantine.ok" || die "quarantine marker is missing"

  race_runtime="$exchange_parent/.codex-race"
  race_guard="$exchange_parent/.codex-race.guard-ready"
  race_quarantine="$exchange_parent/.codex-race.quarantine-fixture"
  race_manifest="$exchange_parent/race-manifest"
  race_hook="$exchange_parent/create-concurrent-quarantine"
  mkdir -p "$race_runtime" "$race_manifest"
  printf 'runtime displaced by exchange\n' >"$race_runtime/opaque-runtime-entry"
  printf '%s\n' 'LIZD_CODEX_MIGRATION_V1 phase=freeze status=ok' \
    >"$race_manifest/freeze.ok"
  printf '%s\n' '#!/usr/bin/env bash' 'mkdir -m 700 -- "$1"' >"$race_hook"
  chmod 700 "$race_hook"
  prepare_runtime_guard "$race_guard"
  export MIGRATION_TEST_AFTER_EXCHANGE_HOOK="$race_hook"
  if quarantine_runtime "$race_runtime" "$race_guard" "$race_quarantine" "$race_manifest" \
    >"$tmp/quarantine-race.out" 2>"$tmp/quarantine-race.err"; then
    die "quarantine accepted a destination created after exchange"
  fi
  unset MIGRATION_TEST_AFTER_EXCHANGE_HOOK
  test -f "$race_runtime/README" || \
    die "quarantine race did not leave the guard at the runtime path"
  test -f "$race_guard/opaque-runtime-entry" || \
    die "quarantine race did not leave displaced runtime at the ready-guard sibling"
  test -d "$race_quarantine" || die "quarantine race destination fixture is missing"
  test ! -e "$race_manifest/quarantine.ok" || \
    die "quarantine race wrote a success marker"
  unset MIGRATION_TEST_GUARD_OWNER_UID
fi

rollback_guard="$tmp/rollback-guard"
rollback_quarantine="$tmp/rollback-quarantine"
rollback_manifest="$tmp/rollback-manifest"
mkdir -p "$rollback_guard" "$rollback_quarantine" "$rollback_manifest"
printf 'guard diagnostic\n' >"$rollback_guard/README"
printf 'damaged database evidence\n' >"$rollback_quarantine/state.sqlite"
declare -F rollback_after_quarantine >/dev/null || \
  die "rollback_after_quarantine library function is missing"
if rollback_after_quarantine "$rollback_guard" "$rollback_quarantine" "$rollback_manifest" \
  >"$tmp/rollback-no-marker.out" 2>"$tmp/rollback-no-marker.err"; then
  die "post-quarantine rollback ran without quarantine.ok"
fi
test -f "$rollback_guard/README" || die "rollback without marker removed the guard"
test -f "$rollback_quarantine/state.sqlite" || \
  die "rollback without marker changed quarantine evidence"

rollback_canonical="$tmp/rollback-canonical"
mkdir -p "$rollback_canonical"
printf '%s\n' \
  '{"type":"session_meta","payload":{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}}' \
  >"$rollback_canonical/merged.jsonl"
rollback_guard_hash="$(hash_file "$rollback_guard/README")"
rollback_quarantine_hash="$(hash_file "$rollback_quarantine/state.sqlite")"
rollback_session_hash="$(hash_file "$rollback_canonical/merged.jsonl")"
chmod 444 "$rollback_guard/README"
chmod 555 "$rollback_guard"
printf '%s\n' 'LIZD_CODEX_MIGRATION_V1 phase=quarantine status=ok' \
  >"$rollback_manifest/quarantine.ok"
rollback_after_quarantine "$rollback_guard" "$rollback_quarantine" "$rollback_manifest"
test "$(hash_file "$rollback_guard/README")" = "$rollback_guard_hash" || \
  die "post-quarantine rollback changed the guard"
test "$(hash_file "$rollback_quarantine/state.sqlite")" = "$rollback_quarantine_hash" || \
  die "post-quarantine rollback changed damaged runtime evidence"
test "$(hash_file "$rollback_canonical/merged.jsonl")" = "$rollback_session_hash" || \
  die "post-quarantine rollback changed a merged session"
test -f "$rollback_manifest/rollback.ok" || die "safe rollback marker is missing"
grep -Fx 'LIZD_CODEX_MIGRATION_V1 phase=rollback status=guarded' \
  "$rollback_manifest/rollback.ok" >/dev/null || die "safe rollback marker content is invalid"

declare -F print_fixed_targets >/dev/null || die "print_fixed_targets library function is missing"
print_fixed_targets >"$tmp/fixed-targets"
printf '%s\n' \
  'hl_gpu_2' \
  'hl_gpu_2@3959909' \
  'hl_gpu_2@3966773' \
  'hl_gpu_2@3966762' \
  >"$tmp/expected-fixed-targets"
cmp "$tmp/expected-fixed-targets" "$tmp/fixed-targets" >/dev/null || \
  die "migration target inventory is not the fixed approved master and three Workers"

declare -F validate_worker_phase_line >/dev/null || \
  die "validate_worker_phase_line library function is missing"
validate_worker_phase_line preflight 3966762 \
  'LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id=3966762 status=ok' || \
  die "valid Worker phase evidence was rejected"
if validate_worker_phase_line preflight 3966762 \
  'LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id=3966762 status=ok extra=unsafe'; then
  die "Worker phase evidence with extra fields was accepted"
fi
if validate_worker_phase_line preflight 3966762 \
  'LIZD_CODEX_MIGRATION_V1 phase=preflight worker_id=3966773 status=ok'; then
  die "Worker phase evidence for a different Worker was accepted"
fi

if [[ "$(uname -s)" == Linux ]]; then
  declare -F read_pid_identity >/dev/null || die "read_pid_identity library function is missing"
  declare -F terminate_recorded_pid >/dev/null || \
    die "terminate_recorded_pid library function is missing"
  sleep 30 &
  test_sleep_pid="$!"
  sleep_identity="$(read_pid_identity "$test_sleep_pid")"
  sleep_starttime="${sleep_identity%%$'\t'*}"
  sleep_executable="${sleep_identity#*$'\t'}"
  test -n "$sleep_starttime" && test -n "$sleep_executable" || \
    die "synthetic PID identity was incomplete"
  if MIGRATION_TERM_TIMEOUT_SECONDS=3 terminate_recorded_pid "$test_sleep_pid" \
    "$((sleep_starttime + 1))" "$sleep_executable" \
    >"$tmp/stale-start.out" 2>"$tmp/stale-start.err"; then
    die "TERM was sent despite a stale PID start time"
  fi
  kill -0 "$test_sleep_pid" 2>/dev/null || \
    die "stale PID identity check terminated the synthetic process"
  if MIGRATION_TERM_TIMEOUT_SECONDS=3 terminate_recorded_pid "$test_sleep_pid" \
    "$sleep_starttime" "$sleep_executable.not-the-recorded-executable" \
    >"$tmp/stale-exe.out" 2>"$tmp/stale-exe.err"; then
    die "TERM was sent despite a stale PID executable"
  fi
  kill -0 "$test_sleep_pid" 2>/dev/null || \
    die "stale PID executable check terminated the synthetic process"
  MIGRATION_TERM_TIMEOUT_SECONDS=3 terminate_recorded_pid "$test_sleep_pid" \
    "$sleep_starttime" "$sleep_executable"
  if kill -0 "$test_sleep_pid" 2>/dev/null; then
    die "TERM-only helper returned while the synthetic process remained"
  fi
  wait "$test_sleep_pid" 2>/dev/null || true
  test_sleep_pid=''
fi

unsafe_patterns=(
  'SIGKILL|kill[[:space:]]+-9'
  'rm[[:space:]]+-rf[^#]*sessions'
  'chown[[:space:]]+-R'
  'rm[^#]*(legacy_root|legacy.*sessions)'
  'rename_with_flags\((quarantine|guard),[[:space:]]*runtime'
)
for unsafe_pattern in "${unsafe_patterns[@]}"; do
  if grep -En "$unsafe_pattern" "$sut" >"$tmp/static-safety.out"; then
    die "static safety inspection matched: $unsafe_pattern"
  fi
done
grep -F 'os.link(temporary_path, destination)' "$sut" >/dev/null || \
  die "canonical publish does not use link(2) no-clobber"

printf 'PASS: migration controller fixture tests\n'
