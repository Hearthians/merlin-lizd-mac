# Task 10 Closure Fix Report

Status: `DONE`

Base: `d26559a736db91c36ad64ba977a1440425a09612`

Commit: the commit containing this report, with subject
`fix: close codex lifecycle races`; its object ID is reported in the agent
handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Late cleanup ownership: `lateThreadCleanupFailureNeverBecomesRecoveryMapping`
  initially failed twice. The installed replacement never received
  `ensureThreadDeleted(thread-late)`, and the following generation did receive
  `resumeThread(thread-late)`, proving the ID had become an ownerless ordinary
  mapping.
- Exact transfer: `failedReplacementCleanupTransfersExactThreadOwnership`
  initially failed with `.unavailable` while the transfer branch was disabled.
  After the minimal branch was enabled, it returned the exact created ID and a
  later recovery did not resume it.
- Shutdown interleaving:
  `cancelledLateStartDoesNotBlockCoordinatorShutdown` initially failed its
  200 ms completion probe because compensation waited for suspended recovery.
  After cancellation became a transfer boundary, it completed in 2 ms without
  waiting for supervisor shutdown and returned the exact ID.
- Focus order: the lifecycle tests initially failed to compile with
  `extra argument 'revision' in call`. The missing API was therefore exercised
  before implementation. The new behavioral test delivers revision 2 before
  revision 1 and rejects the late older request; the existing slow-effect test
  continues to cover ordered A-to-B publication with A completing late.

## Ownership semantics

- Once an old generation returns a late-created ID, the supervisor installs
  explicit pending-compensation ownership before its first suspension. Pending
  IDs are distinct from `mappedThreadIDs`; recovery explicitly excludes them,
  and event-forwarder admission rejects them.
- Compensation never calls the detached client. It acquires an installed or
  replacement generation, calls idempotent `ensureThreadDeleted`, and validates
  that exact generation token after the RPC. Confirmed deletion removes the
  process mapping proof and pending ownership.
- If current-generation deletion fails, startup becomes terminal, cancellation
  begins, or shutdown wins, pending ownership is removed and `startThread`
  returns the exact ID. `CodexSessionCoordinator.resolveThread` then uses its
  existing durable `insertIfAbsent`/orphan-compensation workflow before any
  resume or turn. Coordinator shutdown cancels and joins pending starts before
  shutting down the agent, so the transferred ID is durably owned rather than
  lost at process exit.
- The pending ID is never resumed as an idle mapping and never receives a
  forwarder. Transfer replays no prompt, turn, tool call, or terminal input;
  the coordinator performs its normal first resume/start sequence only after
  durable ownership is established.

## Focus publication semantics

- `TerminalTabsModel` allocates each focus publication revision synchronously
  on the MainActor before creating the cross-actor task.
- Registration revalidates its exact token, session, and current selected tab
  after suspension, then allocates a fresh publication revision.
- `TerminalEndpointFocusArbiter` records the highest published revision and
  ignores older arrivals independently of task scheduling or effect completion
  order.

## Review

- Standards axis: no hard repository-standard violations. A preliminary
  write-only pending-state smell was closed by making recovery and forwarder
  admission consult the state. The duplicated race-test setup remains local so
  each ownership outcome stays explicit.
- Spec axis: compliant; no missing closure requirement, scope creep, or
  technically incorrect implementation was found.

## Verification

- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerSupervisorTests`
  — 22/22 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppLifecycleSupportTests`
  — 3/3 passed.
- `/usr/bin/swift run MerlinLizdCoreTests --filter CodexAppServerContractTests`
  — 76/76 passed.
- `./scripts/test.sh` — 681/681 tests in 45 suites passed.
- `/usr/bin/swift build` — passed.
- `git diff --check` — passed.
- No files under `Vendor`, `Packaging`, or `Assets` changed. Task 11 was not
  implemented.

## Remaining concerns

- The first final full-suite attempt observed one transient existing
  `app-server transport` timing failure. The transport suite then passed 62/62
  in isolation and the fresh full-suite rerun passed 681/681. No closure-specific
  failure remained reproducible.
