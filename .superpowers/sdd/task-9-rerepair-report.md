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

---

# Task 9 post-fix review repair addendum

Base: `690bf7c`

## Outcome

All four Important findings in `task-9-postfix-review-findings.md` are repaired
in one TDD wave. The changes remain confined to Core, the Codex adapter, and
their tests; no App, Vendor, or Task 10 files changed.

## RED

The first full RED run executed 642 tests and recorded 12 issues, all on the
new deterministic seams:

- an indeterminate pre-rename candidate was neither retained nor reconciled,
  while the winner case also lacked volatile ownership;
- a suspended AgentEvent consumer was removed during producer overflow and
  could observe a buffered post-gap record;
- Stop followed by shutdown completed agent shutdown before the exact steer
  cleanup, and Delete began remote deletion before that cleanup;
- a slow activity cursor received a post-gap approval transition before an
  explicit reconciliation event.

The RED suite also established that nil-cursor and exact-cursor stream behavior
must be pull-driven: producers may only append to their bounded ring and wake a
single suspended waiter; they do not yield buffered data or gaps.

## GREEN implementation

1. Pre-rename insert ambiguity now retains the returned candidate ID in the
   existing bounded volatile orphan set before the reservation is released.
   Every later successful exclusive recovery reconciles that set first. A
   durable winner clears volatile ownership without deletion; a proven loser
   is idempotently deleted before replacement creation; failed compensation is
   durably recorded and remains visible. Direct tests cover later absence,
   later winner, and one-attempt failed compensation persistence.
2. AgentEvent delivery now uses the adapter's 512-record replay ring as the
   sole buffer. Each subscriber owns a cursor and at most one checked waiter.
   A pull atomically returns the next retained record or a terminal gap before
   any post-gap record. Cancellation, thread deletion, crash, and shutdown
   remove the exact subscriber and resume its waiter.
3. Termination cleanup now has an exact operation UUID. Waiters bind to that
   UUID and only its owner can finish and resume them. Stop, Delete, and
   shutdown join pre-existing steer cleanup; Stop owns any later active-turn
   cleanup through router termination, event-consumer drain, and agent
   interrupt. Shutdown no longer cancels an admitted Stop before joining it.
4. Coordinator activity delivery now uses the 64-transition history ring as
   the sole buffer, with a per-subscriber cursor and one cancellation-clean
   waiter. A nil cursor receives a current reconciliation on first pull. An
   exhausted cursor receives one current history-gap snapshot before any later
   approval transition; retained requested/resolved transitions remain exact
   and ordered.

## GREEN checkpoints

- `CodexSessionCoordinatorTests`: 63 tests in 2 matched suites passed,
  including all candidate, exact termination, and activity-cursor cases.
- `CodexAppServerContractTests`: 69 tests in 1 suite passed, including exact
  512-record replay, nil-cursor gap, and a deterministically suspended live
  consumer.
- A complete repository run before the final added compensation assertion
  passed all 642 tests in 43 suites. The final complete run is recorded below.

## Final verification

- `./scripts/test.sh 2>&1 | rg -C 3 'recorded an issue|Test run with'`:
  **643 tests in 43 suites passed** in 1.625 seconds.
- One immediately preceding parallel full run completed with two issues whose
  names fell outside the captured tail; both Task 9 focused suites remained
  green, and the immediate complete rerun above was clean. This repository's
  previously documented parallel descriptor-lifetime flake remains deferred;
  no unrelated product change was made without a reproducible failing case.
- `CodexSessionCoordinatorTests`: **63/63 passed** after the last compensation
  persistence assertion.
- `CodexAppServerContractTests`: **69/69 passed**.
- `/usr/bin/swift build`: passed; `Build complete! (0.77s)`.
- `git diff --check`: exited 0 with no output.
- Scope audit lists only this report, two Task 9 production files, and three
  Task 9 test files. No App, Vendor, or Task 10 file changed.
- Self-review of `690bf7c..HEAD`: no additional Critical or Important defects
  found. Event and activity publishers never yield consumer data; exact
  waiter teardown, termination ownership, bounded orphan admission, and
  durable winner/loser decisions are covered at their concurrency seams.

---

# Task 9 final-review repair addendum

Base: `17b54a7`

## Outcome

All six Critical and Important findings in
`task-9-final-review-findings.md` are repaired in the Task 9 Core/adapter
boundary. Core remains protocol-neutral. No files under `Sources/MerlinLizdApp`
or `Vendor` changed.

## Repairs and design decisions

1. The transport now retains the requested `threadId` in the exact correlated
   pending request and recognizes only the real Codex 0.144.2 shapes
   `thread not loaded: <id>` and
   `no rollout found for thread id <id>`. Classification requires the exact
   response ID, method, `-32600` code, requested thread ID, and byte-exact
   message. Wrong IDs, codes, methods, and whitespace remain `.other`; raw
   remote text remains transport-internal. The fresh-adapter deletion retry
   fixture now uses the real response shape.
2. `CodexConversationStoring` now exposes an exclusive
   `recoverDurableSnapshot()` decision boundary. The file store takes the
   exclusive lock, rereads the authoritative envelope, and successfully
   `fsync`s its containing directory before returning the winner. Creation
   recovery never accepts a shared-read observation, and never compensates a
   candidate when exclusive reread/resync fails. It retries only after durable
   recovery proves the mapping absent; candidate compensation occurs only
   after a successful durable recovery proves that candidate is not the
   winner.
3. Event replay uses one bounded stream slot. Initial retained records are one
   bounded batch backed by the existing 512-record ring. A nil cursor receives
   an explicit terminal gap if the ring is already truncated. For live
   overflow, `.dropped` is decoded as the actual missing delivery; the gap
   replaces the buffered post-gap delivery and the stream terminates, so a
   consumer observes exactly one truthful gap before any later data. Core
   reduces a replay batch record-by-record with its existing sequence checks.
4. Stop and Delete now share the exact admitted `StopOperation` per key.
   Deletion joins that operation before durable deletion and cannot run a
   second teardown around a suspended Stop. Exact operation IDs make cleanup
   idempotent for both waiters, preventing a late Stop from recreating deleted
   session state.
5. Stop/Delete admission synchronously cancels the current pending start, and
   teardown joins it before event-consumer drain. Each `PendingStart` carries
   its start ID and lifecycle revision. Ownership is revalidated after thread
   resolution, router preparation, registry reconciliation, remote start, and
   router confirmation; stopping, deletion, shutdown, or token replacement
   blocks every later commit. Deterministic tests suspend the terminal keyboard
   transition after router preparation is installed but before `beginTurn`
   returns, then join the submitting task to prove no remote `startTurn` call.
6. Steer-failure termination ownership is now released unconditionally with a
   `defer` around the lifecycle-revision-guarded state publication. Shutdown
   can therefore drain the exact termination token after it invalidates the
   stale state writer, reaches `agent.shutdown()`, and returns.

## RED-to-GREEN commands and observed output

`MerlinLizdCoreTests` is an executable target, so `swift test --filter` cannot
select individual Swift Testing cases in this repository. Every focused
checkpoint therefore used the repository command `./scripts/test.sh`; the
named cases execute sequentially inside the coordinator, transport, and
contract suites.

- Exact absence classification: RED was 629 tests with three issues (the fresh
  adapter remained tombstoned and both real message classifications were
  `.other`). GREEN was 629/629, including
  `remote absence classification requires the correlated thread ID` and
  `fresh adapter completes Core retry after remote delete stage persistence
  fails`.
- Durable recovery: RED failed
  `repeated post-rename sync failure stays indeterminate` by accepting the
  visible winner and failed
  `authoritative reread failure never compensates an unknown winner` by
  deleting it. GREEN was 631/631; the strengthened successful-recovery case
  also proved two sync calls and normal resume/start progress.
- Replay overflow: RED was 632 tests with two issues: the slow subscriber
  consumed a record before a gap and the nil cursor silently received retained
  replay. GREEN was 632/632, including exact-cursor 512-record replay,
  nil-cursor exhaustion, and slow live overflow.
- Shared Stop/Delete and router-prepared start ownership: RED was 635 tests
  with six issues. Deletion completed around a suspended Stop and resurrected
  state; both Stop and Delete allowed `startTurn` through the router-prepared
  gap. GREEN passed all three new cases and the full coordinator suite.
- Shutdown/steer cleanup: RED failed
  `shutdown drains stale steer-failure termination ownership` because shutdown
  never completed after the lifecycle revision changed. GREEN completed
  shutdown and recorded exactly one agent shutdown call.

The exact new or strengthened regression cases are:

- `remote absence classification requires the correlated thread ID`
- `fresh adapter completes Core retry after remote delete stage persistence
  fails`
- `post-rename sync ambiguity never compensates the durable winner`
- `repeated post-rename sync failure stays indeterminate`
- `authoritative reread failure never compensates an unknown winner`
- `slow live streams expose one gap before buffered post-gap records`
- `nil event cursors report truncated replay before any record`
- `deletion joins an admitted stop before removing durable state`
- `stop cancels a router-prepared start before remote turn creation`
- `deletion cancels a router-prepared start before remote turn creation`
- `shutdown drains stale steer-failure termination ownership`

## Final verification

- `./scripts/test.sh 2>&1 | rg 'recorded an issue|Test run with|Suite
  "app-server transport"|Suite "Codex session coordinator"'`:
  `app-server transport` passed, `Codex session coordinator` passed, and all
  **636 tests in 43 suites passed** in 1.564 seconds.
- One preceding parallel full run reproduced the review's deferred descriptor
  lifetime flake in `app-server transport`; the immediate final full rerun
  above was clean. No product change was made for that pre-existing Minor.
- `/usr/bin/swift build`: passed; `Build complete! (0.08s)`.
- `git diff --check`: exited 0 with no output.
- Self-review of `17b54a7..HEAD`: no additional Critical/Important defects
  found; no App or Vendor files changed.

## Deferred Minor follow-up

As directed, the final review's Minors remain outside this repair wave:
assistant and envelope byte bounds, generic gate/deadline cancellation drain,
the parallel descriptor-lifetime test determinism concern, and future
extraction of the coordinator's per-key lifecycle owner.
