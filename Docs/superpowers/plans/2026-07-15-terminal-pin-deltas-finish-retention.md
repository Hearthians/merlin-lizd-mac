# Terminal Pin Deltas and Finish Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make registry subscriptions an exact replayable pin-state delta stream and retain temporary panes through every pre-close cancellation path.

**Architecture:** Give every pin a stable identity composed of its exact turn handle and binding token, while keeping mutable phase/turn data in the pin value. Advance one registry revision after each observable state mutation and publish an ID-addressable bounded delta; consumers rebuild from the authoritative snapshot after overflow. Route finish interruptions that occur before close through the existing structured retention/audit helper.

**Tech Stack:** Swift 6, Swift actors and `AsyncStream`, Swift Testing, existing terminal/router fakes.

## Global Constraints

- Work only in `/Users/bytedance/Documents/work/merlinhub/.worktrees/tmux-codex-ui` on `codex/tmux-codex-ui`.
- Preserve exact handle and immutable binding-token lifecycle checks; add no raw or tokenless fallback.
- Registry lifecycle entry points remain Core-internal; App-facing registration and subscription remain public.
- Event buffering remains newest-one and no event or pin-loss history is stored.
- Every production change follows a witnessed deterministic RED test.
- Tests never call live Merlin, SSH, tmux, Codex, or network services.

---

### Task 1: Publish Exact Pin-State Deltas

**Files:**
- Modify: `Sources/MerlinLizdCore/TerminalEndpointRegistry.swift`
- Modify: `Tests/MerlinLizdCoreTests/TerminalEndpointRegistryTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TerminalToolRouterTests.swift`

**Interfaces:**
- Consumes: existing exact `AgentTurnHandle`, `TerminalEndpointBindingToken`, and bounded registry subscription.
- Produces:

```swift
public struct TerminalEndpointPinID: Hashable, Sendable {
    public let handle: AgentTurnHandle
    public let bindingToken: TerminalEndpointBindingToken
}

public struct TerminalEndpointPin: Equatable, Sendable {
    public let id: TerminalEndpointPinID
    public let turnID: AgentTurnID?
    public let phase: TerminalEndpointPinPhase
    public let conversationKey: TerminalConversationKey
    public let endpointID: TerminalEndpointID
}

public enum TerminalEndpointRegistryEvent: Equatable, Sendable {
    case upsert(TerminalEndpointPin, revision: UInt64)
    case removed(TerminalEndpointPinID, revision: UInt64)
    case pinLost(TerminalEndpointPinLoss, revision: UInt64)
    case reconciliationRequired(revision: UInt64)
}

public struct TerminalEndpointRegistrySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let pins: [TerminalEndpointPinID: TerminalEndpointPin]
}
```

- [ ] **Step 1: Write failing exact-delta tests**

Add deterministic tests that initialize consumer state from `subscribe()`, then apply events by `pin.id`:

```swift
switch event {
case let .upsert(pin, revision):
    knownPins[pin.id] = pin
    knownRevision = revision
case let .removed(id, revision):
    knownPins.removeValue(forKey: id)
    knownRevision = revision
case let .pinLost(loss, revision):
    knownPins.removeValue(forKey: loss.pin.id)
    knownRevision = revision
case let .reconciliationRequired(revision):
    let snapshot = await registry.pinSnapshot()
    knownPins = snapshot.pins
    knownRevision = snapshot.revision
    #expect(snapshot.revision == revision)
}
```

Cover empty subscription → prepare upsert → claim upsert → loss, prepared snapshot → active upsert → loss without a ghost, direct confirm upsert, normal prepared and active release removal, overflow reconciliation, and both subscription/unregister actor orderings.

- [ ] **Step 2: Run RED**

Run:

```bash
/usr/bin/swift run MerlinLizdCoreTests --filter 'TerminalEndpointRegistryTests'
```

Expected: compile failures for missing `TerminalEndpointPinID`, dictionary snapshots, and upsert/removal event cases, proving the old loss-only stream cannot satisfy the tests.

- [ ] **Step 3: Implement stable IDs and one mutation publisher**

Add a helper used only after state mutation:

```swift
private func publishPinMutation(
    _ event: (UInt64) -> TerminalEndpointRegistryEvent
) {
    pinRevision += 1
    publish(event(pinRevision))
}
```

Publish `.upsert` after initial stored-binding insertion and after prepared→claimed mutation through either claim or direct confirm. Publish `.removed` once when prepared/active changes to releasing. Publish `.pinLost` once after the endpoint-loss phase mutation. Idempotent calls and non-visible preparing→prepared or pinLost→releasing transitions do not advance revision.

- [ ] **Step 4: Run GREEN and exact ABA regressions**

Run:

```bash
/usr/bin/swift run MerlinLizdCoreTests --filter \
  'TerminalEndpointRegistryTests|TerminalToolRouterTests'
```

Expected: exact consumer, overflow, actor-order, stale-generation ABA, and router suites pass.

---

### Task 2: Retain Every Pre-Close Finish Interruption

**Files:**
- Modify: `Tests/MerlinLizdCoreTests/TerminalToolTestSupport.swift`
- Modify: `Tests/MerlinLizdCoreTests/TerminalToolRouterTests.swift`
- Modify: `Sources/MerlinLizdCore/TerminalToolRouter.swift`

**Interfaces:**
- Consumes: `retainExistingLease(_:reason:operationID:turn:binding:)` before mutation preparation and `retainExistingLease(_:reason:preparation:turn:)` after preparation.
- Produces: no new public API; all pre-close interruption paths return `.temporaryPaneFinished(.retained(..., reason: .interrupted))` or the existing provenance-rich audit-unavailable error.

- [ ] **Step 1: Add deterministic observe and approval cancellation tests**

Extend only the terminal test fake with a cancellable observe gate:

```swift
func blockObserves(
    on gate: TerminalToolTestGate?,
    checkCancellationAfterGate: Bool = false
) {
    observeGate = gate
    checkCancellationAfterObserveGate = checkCancellationAfterGate
}
```

Create a lease, block the initial finish observe, cancel, release the gate, and assert retention, exact provenance/reason, request→retained journal order, and zero close calls. Separately start finish, wait for its approval request, cancel it, and assert the pre-existing request/screen/risk/approval-cancelled/result-failure sequence is followed by structured retained audit, with the live lease retained and no close.

- [ ] **Step 2: Run RED**

Run:

```bash
/usr/bin/swift run MerlinLizdCoreTests --filter 'TerminalToolRouterTests'
```

Expected: initial observe cancellation throws `interrupted` without retention; pending approval cancellation also throws `interrupted` without setting/auditing the lease reason.

- [ ] **Step 3: Route typed interruption through retention**

In the initial observe catch, call the no-preparation retention helper with `.interrupted`. Around `prepareMutation`, retain on both raw `CancellationError` and `TerminalToolRouterError.interrupted`; preserve the existing `auditUnavailable` mapping. Keep cancellation checks immediately after approval and before close, and keep the close catch behavior that retains only while the lease is still live.

- [ ] **Step 4: Run GREEN with journal regressions**

Run:

```bash
/usr/bin/swift run MerlinLizdCoreTests --filter \
  'TerminalToolRouterTests|TerminalOperationJournalTests'
```

Expected: both cancellation tests and existing post-approval, validation, probe, close, retention, and audit-unavailable tests pass.

---

### Task 3: Verify, Report, and Commit the Closure

**Files:**
- Modify: `.superpowers/sdd/task-5-report.md` (ignored evidence report)
- Commit: all tracked source, test, support, and plan changes from Tasks 1–2.

- [ ] **Step 1: Run fresh focused verification**

```bash
/usr/bin/swift run MerlinLizdCoreTests --filter \
  'TerminalEndpointRegistryTests|TerminalToolRouterTests|TerminalOperationJournalTests'
```

- [ ] **Step 2: Run fresh repository verification**

```bash
./scripts/test.sh
/usr/bin/swift build
git diff --check
```

- [ ] **Step 3: Audit scope and exactness**

```bash
rg -n '^    public func (prepareTurn|claimPreparedTurn|confirmTurnID|binding|releaseTurn|releasePrepared)' Sources/MerlinLizdCore/TerminalEndpointRegistry.swift
rg -n 'registry\.(prepareTurn|claimPreparedTurn|confirmTurnID|binding|releaseTurn|releasePrepared)\([^\n]*threadID' Sources Tests
git status --short
```

Expected: no public/raw lifecycle matches and only intended files are modified.

- [ ] **Step 4: Update the ignored report and commit**

Record RED/GREEN evidence, final counts, and the resulting SHA in `.superpowers/sdd/task-5-report.md`, then:

```bash
git add docs/superpowers/plans/2026-07-15-terminal-pin-deltas-finish-retention.md \
  Sources/MerlinLizdCore/TerminalEndpointRegistry.swift \
  Sources/MerlinLizdCore/TerminalToolRouter.swift \
  Tests/MerlinLizdCoreTests/TerminalEndpointRegistryTests.swift \
  Tests/MerlinLizdCoreTests/TerminalToolRouterTests.swift \
  Tests/MerlinLizdCoreTests/TerminalToolTestSupport.swift
git commit -m "fix: publish exact terminal pin deltas"
```

## Completion Criteria

- A consumer can reproduce the current exact pin dictionary from any atomic snapshot plus subsequent timely events, or rebuild it after bounded overflow.
- Prepared→active mutation replaces the same stable ID and endpoint loss removes it without a ghost.
- New pins and normal releases are visible at unique monotonic revisions.
- Every pre-close finish cancellation retains and audits the live lease with typed interrupted provenance, while audit failure remains provenance-rich and no close occurs.
- Focused tests, full tests, app build, whitespace validation, exact API audit, and tracked worktree status are clean.
