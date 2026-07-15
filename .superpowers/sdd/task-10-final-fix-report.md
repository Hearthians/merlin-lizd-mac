# Task 10 Final Fix Report

Status: `DONE`

Base: `b4faa109f581ed11d9884d75c3dea72d4c7c1a08`

Commit: the commit containing this report, with subject
`fix: finalize codex lifecycle ownership`; its object ID is reported in the
agent handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Coordinator/supervisor shutdown:
  `shutdownCompletesAfterDurableTransferredStart` gated the old generation's
  `startThread`, crashed it into suspended recovery, waited until coordinator
  shutdown cancelled that exact call, and then returned the late ID. Before
  the fix, shutdown did not complete within the deterministic 200 ms probe
  because `resolveThread` resumed after durable insertion and waited the bare
  recovery task. The RED run failed after 211 ms.
- Recovery waiter ownership:
  `recoveryWaitersHaveExactCancellationOwnership` placed two callers behind
  one suspended recovery and cancelled one. Before the fix, the cancelled
  caller did not complete within 200 ms because both callers awaited the
  shared task directly.
- Exact deletion terminal semantics:
  `exactCleanupSuccessCannotTransferDeletedThread` recorded remote deletion,
  held its response, detached the replacement generation, then cancelled the
  original start. Before the fix, the start returned the already-deleted exact
  ID and its mapping proof remained installed.
- Focus monotonicity: `focusRevisionMustIncreaseStrictly` first accepted one
  endpoint at revision 4, then delivered a stale endpoint at the same revision.
  Before the fix, the stale endpoint was applied.
- The first exact-deletion RED also exposed the missing shared mapping-store
  injection seam for scripted generation factories as a compile error. The
  seam was added minimally, after which the behavioral RED above was observed.

## Cancellation waiter ownership and shutdown result

- Each `RecoveryOperation` owns a dictionary of waiter UUIDs and checked
  continuations. A caller waiting in `readyGeneration` registers one exact
  waiter under a cancellation handler; caller cancellation removes and resumes
  only that waiter and never cancels the shared recovery task.
- `clearRecovery` removes the operation and wakes every remaining waiter after
  replacement success, terminal recovery failure, or normal recovery exit.
  Supervisor shutdown detaches the recovery operation, wakes all waiters, then
  cancels and joins its task. Actor isolation plus remove-before-resume gives
  every continuation one owner and prevents duplicate resumes or dead waiter
  metadata.
- `readyGeneration` checks cancellation before admission and immediately after
  every recovery wake. All Core-facing client operations therefore inherit the
  cancellation-aware shared recovery boundary.
- After a transferred ID wins durable insertion, `resolveThread` now checks
  cancellation before installing an event consumer or calling `resumeThread`.
  The committed record is not rolled back or compensated. The integration
  GREEN completed coordinator shutdown in 11-18 ms, retained the exact durable
  record, and issued no resume for the late ID.

## Exact deletion terminal semantics

- `ensureThreadDeleted` is exact and idempotent. Once its correlated RPC
  returns success, a later generation detach cannot recreate the deleted ID.
  Both direct cleanup and late-thread compensation therefore remove the
  mapping proof/local ownership and accept success without a post-response
  generation-token rejection.
- Mutable operations retain their generation-token validation because their
  late results can still corrupt replacement state. Exact deletion is the
  terminal exception.
- The deterministic GREEN proves the deleted ID is not transferred, its
  mapping proof is absent, no second generation confirms absence, and no
  replacement resumes it.

## Focus revision behavior

- `TerminalEndpointFocusArbiter` accepts only revisions strictly greater than
  the highest accepted revision. Older and same-revision arrivals are ignored.
- The existing reverse-arrival and slow-effect tests remain green, and the new
  same-revision test proves a stale endpoint cannot replace the accepted one.

## Verification

- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerSupervisorTests`
  — 24/24 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexSessionCoordinatorTests`
  — 70/70 passed across the coordinator and matched activity suite.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppLifecycleSupportTests`
  — 4/4 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerContractTests`
  — 76/76 passed.
- `./scripts/test.sh` — 685/685 tests in 45 suites passed.
- `/usr/bin/swift build` — passed.
- `git diff --check` — passed.
- The scoped diff contains no Task 11, `Vendor`, `Packaging`, or `Assets`
  changes.

## Remaining concerns

None. An independent reviewer agent could not be dispatched because the active
agent concurrency limit was already full; the diff received a local read-only
race/ownership review followed by all required focused and full verification.
