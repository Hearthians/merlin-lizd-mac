# Task 9 second repair report

Base: `99be439`

## Outcome

All Critical and Important findings in `task-9-rereview-findings.md` are
repaired. Core remains protocol-neutral. No files under `Sources/MerlinLizdApp`
or `Vendor` changed.

## Repairs by finding

1. `ensureThreadDeleted` now proves the remote postcondition on every retry,
   including a genuinely fresh adapter with an empty mapping store. It probes
   `thread/read`, validates the returned thread identity, deletes an existing
   thread, and accepts absence only for the exact observed Codex 0.144.2
   `-32600` outcomes: `thread not loaded` for read and `no rollout found` for
   delete. The transport converts those messages immediately to a closed,
   sanitized classification; raw remote messages never cross the transport
   error boundary. Every other response remains ambiguous and preserves the
   Core tombstone.
2. The file store has a deterministic post-rename/pre-directory-fsync fault
   seam. After two failed insert attempts, the coordinator rereads the locked
   authoritative envelope and never compensates the candidate when its thread
   is the observed on-disk winner.
3. `snapshot()` now takes the shared file lock and rereads the authoritative
   envelope, so already-open store and coordinator instances observe mappings,
   deletion tombstones, and completed deletion written by another instance.
4. Stop installs a per-key guard and lifecycle revision synchronously,
   single-flights concurrent callers, removes prepared/active ownership, and
   quiesces the exact router turn before draining its event consumer or pending
   start. Approval attempts for stopping or deleting ownership are denied.
5. Agent event EOF, buffer loss, and explicit replay gaps crash the exact router
   turn first and interrupt the real remote active turn before a replacement
   submit can proceed.
6. Agent events carry a protocol-neutral monotonic per-thread sequence. The
   adapter retains a hard 512-record replay ring and accepts an exact cursor;
   exhausted history is a terminal `replayGap`, distinct from ordinary EOF.
   The coordinator records the last reduced sequence, skips replay overlap,
   and rejects forward gaps. Final deletion and adapter shutdown remove replay
   and sequence state.
7. Shutdown now prevents late lifecycle and subscription admission, cancels and
   awaits pending starts, Stops, archives, deletions, terminations, event
   consumers, restoration, and registry/router installation and consumer
   tasks before `agent.shutdown`. Registry and router subscriptions have exact
   IDs that are explicitly canceled on failed installation and shutdown;
   stream continuations are finished without spawning deferred cleanup work.
8. Shared-start and termination waiters have UUID ownership plus cancellation
   handlers that remove and resume only the canceled waiter without canceling
   the shared operation or accumulating stale continuations.
9. Router activity projection tracks a strict monotonic source revision. Exact
   transition replay is deduplicated against later live delivery, and a stale
   snapshot that returns after a newer live transition cannot overwrite it.
10. Router mutations are recorded before live yield in a hard 64-transition
    ring. Reconciliation atomically captures snapshot plus replay, or returns
    an explicit history gap. The coordinator has its own hard 64-transition
    activity ring and `activityEvents(after:)`; a cursor older than retained
    history receives `transitionHistoryGap`. Approval upsert and remove remain
    an exact requested/resolved pair even when both are lost from the live
    router buffer.
11. Remote thread creation reserves capacity first against the union of durable
    orphans, volatile orphans, and in-flight reservations. The 64-entry orphan
    bound therefore fails before another remote create once retention is full.
12. Steer-failure cleanup captures the per-key lifecycle revision. A newer Stop
    changes that revision and deterministically owns the final interrupted
    state, so stale cleanup cannot publish a later protocol failure.

## RED-to-GREEN coverage

Twenty added or strengthened targeted cases cover the true fresh-adapter
existing/absent/ambiguous remote states, post-rename ambiguity, cross-instance
snapshot refresh, waiter cancellation, Stop/approval ordering and
single-flight behavior, stale steer cleanup, remote event EOF and replay gaps,
partial replay overlap, bounded orphan admission, shutdown task/subscription
drain, stale activity snapshots, total approval live loss with replay dedupe,
and both router and coordinator history exhaustion seams.

The key RED observations were a zero-write fresh delete, compensation deleting
the durable post-rename winner, stale already-open snapshots, canceled callers
remaining suspended, approval release during Stop drain, duplicate assistant
delta reduction after replacement replay, requested/resolved loss after router
overflow, stale snapshot overwrite, and snapshot-only downstream overflow.
Each corresponding regression is GREEN.

## Verification

- Targeted Critical and lifecycle checkpoints: passed.
- Agent cursor and transition-ring checkpoints: passed.
- `./scripts/test.sh`: 628 tests passed in 43 suites.
- `/usr/bin/swift build`: passed.
- `git diff --check`: passed.
- No App or Vendor files changed.

## Deliberate limits and deferred minors

The remote absence proof deliberately recognizes only the exact Codex 0.144.2
method/code/message combinations observed in the second review. Changed text,
codes, transport failures, malformed identities, and other server outcomes are
not guessed; they retain the deletion tombstone for retry.

The unavoidable process-crash window after remote `startThread` returns but
before Core can retain the returned ID is unchanged; closing it requires a
server-side idempotency key or transactional create API.

The review's deferred minors remain deferred: assistant/envelope byte bounds,
cancel-and-drain deadline helpers, cancellation-aware generic gates, and a
future extraction of the coordinator's per-key lifecycle/activity projection.
