# Task 9 repair report

Base: `0eede22`

## Outcome

All Critical and Important findings in `task-9-review-findings.md` are repaired.
The implementation remains protocol-neutral in Core, makes no App or Vendor
changes, and adds deterministic RED-to-GREEN coverage for each repaired race or
recovery boundary.

## Repairs by finding

1. Deletion now holds a per-conversation lifecycle gate across stop and every
   durable stage. Submit, steer, archive, and thread resolution reject deletion
   tombstones. An already-admitted archive drains before deletion side effects,
   later archives receive the typed deletion-pending error, concurrent deletes
   single-flight, and relaunch is covered from every tombstone stage.
2. Initiating-submit cancellation unwinds prepared or confirmed ownership. A
   canceled submit waiting for a shared start returns without steering.
3. Stop, start cancellation/error cleanup, steer failure, deletion, and
   shutdown release exact router ownership before any potentially suspended
   remote interrupt. Shutdown cancels and drains owned start, turn, consumer,
   and subscription tasks.
4. A per-key terminating gate prevents steering a remotely completed turn and
   starts the queued prompt once after router cleanup.
5. Exact consumer tokens plus stopping/deleting guards reject queued late
   events after stop or mutation begins.
6. Archive reconciliation executes the persisted `desiredArchived` value.
   Opposite concurrent requests fail with a typed conflict at both durable
   archive stages.
7. Deletion retries use a minimal idempotent postcondition contract,
   `ensureThreadDeleted`. Core invokes it only for thread IDs created by this
   client and durably owned by Core. The adapter treats an already-unmapped ID
   as success; when a mapping exists, it performs the strict delete and
   propagates failures. Fresh-adapter restart coverage verifies recovery after
   the remote delete succeeds but stage persistence fails.
8. Failed new-thread persistence plus failed cleanup records a bounded,
   retryable orphan reference. Durable orphans survive relaunch; if that write
   also fails, a bounded volatile orphan and sanitized recoverable failure are
   retained rather than discarding both failures.
9. Conversation creation uses compare-and-insert under the store file lock.
   The winner remains immutable and a losing coordinator compensates its remote
   thread, with orphan recovery if compensation fails.
10. Registry and router subscription installation are actor-owned
    single-flight operations, and shutdown cancels and drains the exact task.
11. Registry consumption applies its authoritative snapshot and revisioned
    reconciliation, including pin loss during turn confirmation.
12. Thread event consumers have exact ownership tokens, remove themselves on
    EOF, fail active ownership explicitly on stream loss, and drain on delete
    and shutdown.
13. Router approval reconciliation emits exact requested/resolved activity by
    owning conversation key without duplicates.
14. Coordinator activity is revisioned and bounded; overflow yields an
    authoritative snapshot so downstream consumers cannot silently miss an
    approval transition.

The only unavoidable creation window is a process crash after the remote
`startThread` call returns but before Core executes any local instruction that
can retain the returned ID. Closing that window would require a server-side
idempotency key or transactional create API; all locally observable failures
after receipt of the ID are now compensated or retained for retry.

## Verification

- Focused repair regressions: 49 tests passed in 3 suites.
- `./scripts/test.sh`: 613 tests passed in 43 suites.
- `/usr/bin/swift build`: passed.
- `git diff --check`: passed.
- No files under `Sources/MerlinLizdApp` or `Vendor` changed.

## Deferred minor observations

As requested by the review, the two minor items are recorded but were not
expanded into this repair:

- Assistant history is bounded by message count, but not yet by encoded byte
  size; persisted envelope reads also lack an explicit byte ceiling.
- The shared test deadline helper does not cancel and drain its operation, and
  its generic test gate is not cancellation-aware.
