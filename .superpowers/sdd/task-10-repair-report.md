# Task 10 Repair Report

Status: `DONE`

Repair base: `1cc4234d8986415642118b09425f8ac62ce82f27`

Commit: the commit containing this report, with subject
`fix: harden codex runtime supervision`; its object ID is reported in the
agent handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Failed-child cleanup: while the child shutdown gate was closed, availability
  remained `ready`, a request created a second generation, and the factory
  reached three creations. A concurrent shutdown caller also returned before a
  gated child shutdown completed.
- Underlying replay gap: the active turn's expected
  `.turnFailed(..., .protocolFailure)` was absent; the first visible record was
  a later delta.
- Generation completion tokens: gated old-generation `startThread`,
  `startTurn`, `resumeThread`, and `deleteThread` all returned success after a
  crash. Thread creation was not compensated, the late turn was not
  interrupted, and late delete removed replacement-generation state.
- Loss awareness: a subscriber stalled across 600 events received retained
  post-gap records instead of a leading replay gap because
  `bufferingNewest(64)` silently evicted deliveries.
- Replacement crash: a candidate that published `.crashed` while its resume
  RPC was gated was installed as ready and was not shut down or retried.
- Production initialize: the production-relevant adapter/transport seam had no
  typed initialization entry point. After that seam was introduced, scripted
  401, `-32601`, and 429 initialize responses exercised the real JSONL path.
- App lifecycle support: tests initially failed to compile because no latest-
  focus arbiter or authoritative notification tracker existed.
- Terminal availability: repeated typed startup demand created another
  factory generation, and a live generation publishing `.overloaded` was not
  detached or reaped.

## Ownership and lifecycle design

- A crash detaches the generation, cancels its observers/forwarders, publishes
  bounded failure state, and installs a uniquely identified recovery task
  before the actor first suspends. That task exclusively owns failed-child
  interrupt, shutdown/reap, backoff, candidate validation, idle resume, and
  eventual installation.
- Recovery candidates are not installed while cleanup, availability setup, or
  idle resume is pending. Their first typed availability is pulled before
  installation. A crashed candidate is shut down and retried; terminal typed
  availability disables further starts. No live generation is overwritten.
- Shutdown installs one shared cleanup task synchronously. Every concurrent or
  later caller awaits it. It cancels retries/startup while still joining the
  mandatory failed-child cleanup, live child shutdown, and event forwarders.
- Resolver failures remain typed before adapter creation. The production
  factory eagerly initializes an adapter and reaps it on initialization
  failure. Only crash-class failures enter exponential recovery.

## Late completion semantics

- Admission returns a `Generation` handle, not a bare client. Every suspending
  client RPC is followed by ownership validation before supervisor state is
  changed or success is returned.
- A late created thread is synchronously sent through idempotent
  `ensureThreadDeleted`; if compensation fails, its identity remains in the
  supervisor's mapped set for safe later recovery rather than becoming an
  unknown remote orphan.
- A late created turn is interrupted and rejected. Late resume, steer,
  archive, unarchive, delete, and ensure-delete completions cannot mutate a
  replacement generation.

## Loss-aware event delivery

- Stable supervisor streams now pull atomically from a 512-record replay ring.
  The actor decides record versus gap in one critical section, so overflow
  reports exactly one gap before any post-gap record and never relies on a
  silently dropping `AsyncStream` buffer.
- Stream lifetime, iterator cancellation, delete, and shutdown remove exact
  subscriber ownership and resume stranded waiters.
- An underlying adapter replay gap publishes exactly one terminal protocol
  failure while the active-turn owner still exists; `publish` then removes it.

## Production classification and App races

- JSONL initialize errors are classified only from the correlated method and
  bounded numeric code into typed authentication, capability, overload, or
  crash errors. Arbitrary message, stderr, JSON data, and credentials are
  ignored. User-visible availability strings remain fixed and sanitized.
- Every terminal registration generation receives a fresh UUID endpoint ID.
  Stale registration guards remain, and asynchronous unregister always retires
  only the exact captured endpoint.
- Focus effects pass through an App-independent actor that serializes effects
  and drains to the latest requested endpoint, so rapid A-to-B selection cannot
  finish with A authoritative.
- Notification reconciliation treats gap snapshots as authoritative: tracked
  IDs absent from the snapshot are removed before current background approvals
  are added. Stale clicks therefore no-op. Delivery text remains fixed and
  bounded, and clicks only invoke the existing selection callback seam.

## Verification

- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerSupervisorTests`
  — 19/19 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerContractTests`
  — 76/76 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppLifecycleSupportTests`
  — 2/2 passed.
- `./scripts/test.sh` — 677/677 tests in 45 suites passed.
- `/usr/bin/swift build` — passed.
- `git diff --check` — passed.
- No files under `Vendor/SwiftTerm`, `Packaging`, or `Assets` changed. Task 11
  drawer UI was not implemented.

Remaining concerns: none.
