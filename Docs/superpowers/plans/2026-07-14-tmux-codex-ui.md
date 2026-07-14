# Tmux Codex UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native bottom Codex drawer to tmux-backed terminal tabs so local Codex can observe and control the exact SwiftTerm-rendered tmux surface, with persistent per-session conversations, explicit keyboard ownership, auditable permissions, and parallel background turns.

**Architecture:** Keep terminal tools, permissions, approvals, conversation identity/routing, temporary-pane leases, and journals in `MerlinLizdCore`. Put all JSONL RPC, Dynamic Tool schema, Codex executable/version handling, and app-server process management in a replaceable `MerlinLizdCodexAdapter` target. Keep SwiftTerm/AppKit capture, PTY writes, runtime composition, notifications, and SwiftUI presentation in `MerlinLizdApp`. One process-wide app-server serves many independent conversations; every active turn pins one visible terminal endpoint until completion or takeover.

**Tech Stack:** Swift 6, Swift Concurrency, SwiftUI/AppKit, SwiftTerm 1.14 local vendor, tmux 3.x fixed commands, Codex CLI app-server v0.144.2 experimental JSONL protocol, Swift Testing, SwiftPM.

## Global Constraints

- Preserve the dependency direction `App/UI -> Core protocols/domain <- Codex adapter`; Core must not import SwiftTerm or expose JSON-RPC/Dynamic Tool wire types.
- V1 enables Codex only for tabs with a resolved tmux identity. Plain local shell tabs remain unchanged and show no active composer.
- A conversation key is stable target identity plus tmux `session_id` and `session_created`; session name, SSH alias, Devbox name, tab UUID, and selected tab are not identity.
- Within one tmux conversation, Codex observes and mutates only the current window and active pane. Relative selection and temporary-pane commands must make the new surface active before any screen read or input. No command may capture hidden-pane contents.
- Background app tabs may keep running independent Codex turns. One conversation has at most one active turn; a prompt submitted during that turn steers it.
- Sending a prompt transfers terminal keyboard ownership to Codex. **Stop and Take Over** interrupts the Codex turn and unsent tool/input work, then restores keyboard ownership; it must not emit Control-C, kill a pane/session, or close the terminal.
- Every terminal side effect is stale-screen guarded, permission checked, and durably journaled before execution. Failure to journal is fail-closed.
- High-risk approval is allow-once or deny and is bound to the canonical input payload, pinned endpoint, and exact expected screen revision. A changed route or screen expires it.
- Temporary panes are closed only after a fixed, visible in-pane shell probe proves an idle shell and no background jobs. Foreground work, probe timeout, missing markers, route drift, or uncertainty retains the pane.
- The app-server inherits the user's existing Codex home/auth/model configuration. Never request, persist, or inject an API key.
- The supported experimental protocol range for this implementation is `>= 0.144.2 && < 0.145.0`. Expanding it requires regenerated fixtures and a reviewed compatibility change.
- Thread start supplies the six `merlin_tmux` Dynamic Tools. Codex 0.144.2 `thread/resume` has no `dynamicTools` field, so resume only mapped threads originally created by this adapter; all non-terminal tools remain disabled at process and thread boundaries.
- The app-server protocol is experimental and is specified for this build by fixtures selected from the installed 0.144.2 generated schema. Do not infer fields from unrelated public Codex surfaces.
- Bound each input batch to 256 semantic events and 32 KiB encoded bytes, purpose text to 500 Unicode scalars, and waits to 120 seconds. Reject oversized tool requests before journaling or touching a terminal.
- Tests must not call live Merlin, SSH, tmux, OpenAI, or Codex services. Use fakes, scripted terminal frames, and checked-in JSONL fixtures. A final manual smoke test may use the user's own tmux session.
- The worktree already contains user changes. Re-read touched files before editing, preserve overlapping work, stage exact paths/hunks, and never reset or discard unrelated changes.
- Each task follows red/green/refactor, runs its focused tests, then runs `./scripts/test.sh` before its scoped Conventional Commit.

---

### Task 1: Persist Stable tmux Session Identity

**Files:**
- Modify: `Sources/MerlinLizdCore/TmuxSessionParser.swift`
- Modify: `Sources/MerlinLizdCore/MerlinCommands.swift:166-198`
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift:181-205,300-325`
- Modify: `Sources/MerlinLizdCore/TerminalState.swift:3-45`
- Create: `Sources/MerlinLizdCore/TerminalConversation.swift`
- Modify: `Sources/MerlinLizdApp/TerminalTabsModel.swift:90-125,225-280,330-390`
- Modify: `Sources/MerlinLizdApp/TmuxSessionBrowserView.swift:215-230`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionParserTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/CommandBuilderTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TerminalStateCodecTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalConversationTests.swift`

**Interfaces:**

```swift
public struct TmuxSessionIdentity: Codable, Hashable, Sendable {
    public let serverSessionID: String       // exact tmux value, e.g. "$3"
    public let createdAtEpoch: Int64
}

public struct TmuxSessionRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: String {
        identity.map { "\($0.serverSessionID)@\($0.createdAtEpoch)" } ?? name
    }
    public let name: String
    public let identity: TmuxSessionIdentity?

    public init(name: String, identity: TmuxSessionIdentity? = nil) {
        self.name = name
        self.identity = identity
    }
}

public struct TerminalTabRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    // existing fields...
    public var tmuxIdentity: TmuxSessionIdentity?

    // Extend the existing initializer with `tmuxIdentity: ... = nil`.
}

public enum TerminalTargetIdentity: Codable, Hashable, Sendable {
    case local
    case devbox(sid: String)
    case worker(devboxSID: String, workerID: String)
}

public struct TerminalConversationKey: Codable, Hashable, Sendable {
    public let target: TerminalTargetIdentity
    public let tmux: TmuxSessionIdentity
}
```

- [ ] **Step 1: Write failing structured-identity and migration tests**

Add parser cases for `training,$3,1784000102`, duplicate identity with a renamed label, malformed IDs/timestamps, and the existing legacy `name` / `name: N windows` fallbacks. Add codec coverage proving old JSON without `tmuxIdentity` decodes with `nil`, while a new record round-trips the identity. Add a discovery rename test proving the record keeps the same identity. Add a same-name recreation test proving `$3@100` and `$9@200` are distinct records. Assert aliases, display names, and tmux rename do not affect `TerminalConversationKey`, while same-name recreation does.

```swift
@Test("structured tmux output preserves server identity")
func parsesStructuredIdentity() {
    let records = TmuxSessionParser.parse("training,$3,1784000102\n")
    #expect(records == [TmuxSessionRecord(
        name: "training",
        identity: .init(serverSessionID: "$3", createdAtEpoch: 1_784_000_102)
    )])
}
```

- [ ] **Step 2: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'tmux session discovery|Terminal tab persistence|Terminal command routing'`

Expected: compilation fails because the identity model and initializer fields do not exist.

- [ ] **Step 3: Parse and request stable identity without shell metacharacters**

Change `listTmuxSessions` to request the comma-delimited format below. Comma is outside the validated session-name alphabet and is safe in the reconstructed remote command; do not use `|`, which would become a shell pipeline.

```swift
let format = "#{session_name},#{session_id},#{session_created}"
let tmuxArguments = ["list-sessions", "-F", format]
// Remote forms keep -F attached, as today:
// tmux list-sessions -F#{session_name},#{session_id},#{session_created}
```

Accept only `serverSessionID` matching `^\\$[0-9]+$` and a nonnegative `Int64` timestamp. Deduplicate structured results by identity and legacy results by name. Make `TmuxSessionRecord.id` use `serverSessionID + "@" + createdAtEpoch` when available. Preserve `identity` when applying discovery rename journals.

- [ ] **Step 4: Persist and propagate identity to tabs**

Make `tmuxIdentity` optional so synthesized `Codable` remains backward compatible. Change `attachExistingSession` to accept the full `TmuxSessionRecord`. For app-created/legacy tabs, add `TerminalTabsModel.resolveTmuxIdentity(for:) async -> TmuxSessionIdentity?`: perform foreground discovery, match the validated session name, verify only one matching identity, persist it, and return it. Failure leaves the terminal working but Codex unavailable. When a tmux rename succeeds, update all tabs whose target and identity match; for unresolved legacy tabs, update only exact target/name matches. Do not rewrite identity.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

Expected: all tests pass; old persisted tabs still decode; rename keeps identity; same-name recreation changes identity.

```bash
git add Sources/MerlinLizdCore/TmuxSessionParser.swift \
  Sources/MerlinLizdCore/MerlinCommands.swift \
  Sources/MerlinLizdCore/TmuxSessionDiscovery.swift \
  Sources/MerlinLizdCore/TerminalState.swift \
  Sources/MerlinLizdCore/TerminalConversation.swift \
  Sources/MerlinLizdApp/TerminalTabsModel.swift \
  Sources/MerlinLizdApp/TmuxSessionBrowserView.swift \
  Tests/MerlinLizdCoreTests/TmuxSessionParserTests.swift \
  Tests/MerlinLizdCoreTests/CommandBuilderTests.swift \
  Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift \
  Tests/MerlinLizdCoreTests/TerminalStateCodecTests.swift \
  Tests/MerlinLizdCoreTests/TerminalConversationTests.swift
git commit -m "feat: persist stable tmux session identity"
```

### Task 2: Define Protocol-Neutral Screens and Semantic Input

**Files:**
- Create: `Sources/MerlinLizdCore/TerminalScreen.swift`
- Create: `Sources/MerlinLizdCore/TerminalInput.swift`
- Create: `Sources/MerlinLizdCore/TerminalSessionPort.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalScreenTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalInputTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalScreenChannelTests.swift`

**Interfaces:**

```swift
public struct TerminalScreenSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let columns: Int
    public let rows: Int
    public let cursor: TerminalCursor
    public let mode: TerminalScreenMode
    public let text: String
    public let significantRuns: [TerminalAttributeRun]
    public let changedRows: [Int]
}

public enum TerminalInputEvent: Codable, Equatable, Sendable {
    case text(String)
    case key(TerminalKey, modifiers: TerminalKeyModifiers)
}

public struct TerminalInputBatch: Codable, Equatable, Sendable {
    public let expectedRevision: UInt64
    public let events: [TerminalInputEvent]
    public let purpose: String
    public let declaredRisk: TerminalRisk
}

public enum TerminalRisk: Int, Codable, Comparable, Sendable {
    case observation, routine, high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TerminalEndpointID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum TerminalKeyboardOwner: Codable, Equatable, Sendable {
    case user, codex
}

public protocol TerminalSessionPort: Sendable {
    func observeScreen() async throws -> TerminalScreenSnapshot
    func sendInput(_ batch: TerminalInputBatch) async throws -> TerminalInputReceipt
    func waitForScreen(_ request: TerminalScreenWaitRequest) async throws -> TerminalScreenWaitResult
    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) async
}
```

- [ ] **Step 1: Write failing frame, diff, encoding, and wait tests**

Use scripted grids for a normal shell, alternate-screen Vim frame, cursor-only change, inverse/selected runs, wide characters, blank trailing cells, and resize. Verify a revision increments only when rendered grid/mode/cursor/attributes change; `changedRows` is compact; text preserves row boundaries while trimming only trailing blank cells. Test normal/application cursor arrow encodings, Enter/Escape/navigation/function keys, Control letters, Option-as-escape-prefix, invalid Control combinations, and UTF-8 text. Test change, stable-for, and timeout waits with an injected `ContinuousClock`-compatible fake.

- [ ] **Step 2: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Terminal screen|Terminal input|Terminal screen channel'`

Expected: the new types are missing.

- [ ] **Step 3: Implement the pure frame reducer and semantic encoder**

Keep raw SwiftTerm cells out of Core. Define a `TerminalGridFrame` made of Unicode graphemes plus Core-owned style flags (`bold`, `underline`, `inverse`, `selected`, `dim`, `italic`). `TerminalScreenReducer.accept(_:)` fingerprints dimensions, cursor, mode, text, and significant runs, then emits a monotonically increasing `TerminalScreenSnapshot`. Put xterm byte encoding in `TerminalInputEncoder.encode(events:keyboardMode:)`; reject impossible modifier/key pairs instead of guessing.

- [ ] **Step 4: Implement an event-driven screen channel**

Add actor `TerminalScreenChannel` with `publish(_:)`, `latest()`, and `wait(_:)`. A `.changed(after:)` waiter resumes on the first greater revision. A `.stable(after:for:)` waiter restarts its clock on every publication and returns only after the requested quiet period. Timeout returns the newest snapshot with `timedOut == true`; it is not an error and never triggers input replay. Cancellation removes the continuation.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCore/TerminalScreen.swift \
  Sources/MerlinLizdCore/TerminalInput.swift \
  Sources/MerlinLizdCore/TerminalSessionPort.swift \
  Tests/MerlinLizdCoreTests/TerminalScreenTests.swift \
  Tests/MerlinLizdCoreTests/TerminalInputTests.swift \
  Tests/MerlinLizdCoreTests/TerminalScreenChannelTests.swift
git commit -m "feat: model rendered terminal control"
```

### Task 3: Add Permission Decisions, Exact Approvals, and Durable Journals

**Files:**
- Create: `Sources/MerlinLizdCore/TerminalPermissionPolicy.swift`
- Create: `Sources/MerlinLizdCore/TerminalApprovalBroker.swift`
- Create: `Sources/MerlinLizdCore/TerminalOperationJournal.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalPermissionPolicyTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalApprovalBrokerTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalOperationJournalTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalPersistenceSupport.swift`

**Interfaces:**

```swift
public enum TerminalPermissionDecision: Equatable, Sendable {
    case allow
    case requireApproval(TerminalApprovalRequest)
    case deny(reason: String)
}

public struct TerminalApprovalScope: Codable, Hashable, Sendable {
    public let payloadDigest: String
    public let endpointID: TerminalEndpointID
    public let screenRevision: UInt64
}

public protocol TerminalOperationJournaling: Sendable {
    func append(_ event: TerminalJournalEvent) async throws
    func entries(for key: TerminalConversationKey) async throws -> [TerminalJournalEvent]
    func deleteJournal(for key: TerminalConversationKey) async throws
}
```

- [ ] **Step 1: Write failing classification and approval-expiry tests**

Cover routine typing/navigation and high-risk signals: destructive deletion, overwrite redirection, disk/process/session termination, force flags, `git push`, credential/auth changes, and accepting a destructive TUI prompt with Enter/Y. Assert effective risk is `max(agentDeclared, deterministicPolicy)`. Assert allow-once matches only canonical payload bytes + endpoint + revision, is consumed once, and expires on any route or revision change. Unknown confirmation prompts must escalate.

- [ ] **Step 2: Write failing journal security/order tests**

Use a temporary Application Support fixture. Assert JSONL records request, screen revision/diff, risk, approval, endpoint, emitted batch, result, and temporary-pane events in order. Assert directories are `0700`, files are `0600`, writes survive re-open, partial trailing JSONL is reported as corruption rather than silently skipped, and deleting one conversation removes only its mapping/journal. Filenames use a SHA-256 storage ID rather than raw target/session labels.

- [ ] **Step 3: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Terminal permission|Terminal approval|Terminal operation journal'`

- [ ] **Step 4: Implement deterministic fail-closed policy and persistence**

Canonicalize the exact `TerminalInputBatch` with sorted-key JSON before hashing. Classify normalized command text conservatively; combine text rules with current-screen prompt context for semantic Enter/Y confirmations. Do not add persistent broad allow rules. The broker stores one continuation per request and supports approve-once, deny, turn cancellation, and screen/endpoint invalidation.

Implement `FileTerminalOperationJournal` as an actor. Create its root with user-only permissions, append one complete JSON object plus newline per fsync boundary, and never write unredacted data to unified logging. Journal request and approval outcome before the side effect. If a pre-action append fails, deny execution; if a post-action append fails, return `auditUnavailable` and block further mutations for that turn.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCore/TerminalPermissionPolicy.swift \
  Sources/MerlinLizdCore/TerminalApprovalBroker.swift \
  Sources/MerlinLizdCore/TerminalOperationJournal.swift \
  Tests/MerlinLizdCoreTests/TerminalPermissionPolicyTests.swift \
  Tests/MerlinLizdCoreTests/TerminalApprovalBrokerTests.swift \
  Tests/MerlinLizdCoreTests/TerminalOperationJournalTests.swift \
  Tests/MerlinLizdCoreTests/TerminalPersistenceSupport.swift
git commit -m "feat: guard and audit terminal actions"
```

### Task 4: Add Fixed tmux Surface Control and Temporary-Pane Leases

**Files:**
- Create: `Sources/MerlinLizdCore/TmuxSurface.swift`
- Modify: `Sources/MerlinLizdCore/MerlinIdentifierValidator.swift`
- Modify: `Sources/MerlinLizdCore/MerlinCommands.swift`
- Modify: `Sources/MerlinLizdCore/TmuxSessionController.swift`
- Modify: `Tests/MerlinLizdCoreTests/CommandBuilderTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionControllerTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TmuxSurfaceTests.swift`

**Interfaces:**

```swift
public struct TmuxSurface: Codable, Equatable, Sendable {
    public let sessionIdentity: TmuxSessionIdentity
    public let windowID: String       // @123
    public let paneID: String         // %456
    public let currentCommand: String
}

public enum TmuxVisibleSelection: Codable, Equatable, Sendable {
    case nextWindow, previousWindow
    case windowIndex(Int)
    case paneLeft, paneRight, paneUp, paneDown, nextPane, previousPane
}

public struct TemporaryPaneLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationKey: TerminalConversationKey
    public let origin: TmuxSurface
    public let temporary: TmuxSurface
}

public struct TmuxRoute: Codable, Equatable, Sendable {
    public let target: TerminalTarget
    public let sessionName: String
    public let expectedIdentity: TmuxSessionIdentity
}

public protocol TmuxSurfaceControlling: Sendable {
    func currentSurface(route: TmuxRoute) async throws -> TmuxSurface
    func select(_ selection: TmuxVisibleSelection, from: TmuxSurface, route: TmuxRoute) async throws -> TmuxSurface
    func createTemporaryPane(from: TmuxSurface, route: TmuxRoute) async throws -> TmuxSurface
    func closeTemporaryPane(_ paneID: String, restoring origin: TmuxSurface, route: TmuxRoute) async throws
}
```

- [ ] **Step 1: Write failing validators, command, and parser tests**

Validate only `@` + digits, `%` + digits, nonnegative window indexes, and existing safe session names. Add exact command tests for:

- current active metadata: `display-message -p -t sessionName -F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}`;
- next/previous window targeted to the validated session name;
- directional/next/previous pane targeted from the verified current `%pane`;
- split targeted to `%pane`, printing `#{window_id},#{pane_id}`;
- kill only the lease `%pane`, then restore the recorded `@window` / `%pane` when still present.

The controller may inspect metadata only for the current active pane and lease-owned pane IDs; do not add `capture-pane`, hidden-pane screen reads, arbitrary tmux strings, `ps`, or shell-command APIs.

- [ ] **Step 2: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Terminal command routing|tmux session mutations|tmux surfaces'`

- [ ] **Step 3: Implement typed fixed commands through the existing safe lanes**

Extend `MerlinCommands` with one builder per structural action and route local/Devbox/Worker exactly like discovery/mutation. Reuse `SSHMasterPool`; use replay `.readOnly` only for metadata reads and `.never` for selection/split/kill. Parse comma-delimited fixed output and verify returned identity equals the expected conversation identity before exposing a surface. Selection must return and verify the now-current surface before the router can observe/input.

- [ ] **Step 4: Implement lease-safe close primitives**

`closeTemporaryPane` accepts only a lease-owned pane ID. It does not decide idleness; Task 5 supplies proof. Kill the temporary pane, then restore the origin window/pane if both still exist. If restore fails, report it without killing any other pane. If the lease pane no longer exists, treat it as retained/lost and do not target a replacement.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCore/TmuxSurface.swift \
  Sources/MerlinLizdCore/MerlinIdentifierValidator.swift \
  Sources/MerlinLizdCore/MerlinCommands.swift \
  Sources/MerlinLizdCore/TmuxSessionController.swift \
  Tests/MerlinLizdCoreTests/CommandBuilderTests.swift \
  Tests/MerlinLizdCoreTests/TmuxSessionControllerTests.swift \
  Tests/MerlinLizdCoreTests/TmuxSurfaceTests.swift
git commit -m "feat: control visible tmux surfaces"
```

### Task 5: Route Tools Through Pinned Endpoints

**Files:**
- Create: `Sources/MerlinLizdCore/TerminalEndpointRegistry.swift`
- Create: `Sources/MerlinLizdCore/TerminalTool.swift`
- Create: `Sources/MerlinLizdCore/TerminalToolRouter.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalEndpointRegistryTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalToolRouterTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TerminalToolTestSupport.swift`

**Interfaces:**

```swift
public struct AgentThreadID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AgentTurnID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum TerminalToolCall: Codable, Equatable, Sendable {
    case observeScreen
    case sendInput(TerminalInputBatch)
    case waitForScreen(TerminalScreenWaitRequest)
    case selectVisibleSurface(TmuxVisibleSelection, expectedRevision: UInt64)
    case createTemporaryPane(expectedRevision: UInt64)
    case finishTemporaryPane(leaseID: UUID, expectedRevision: UInt64)
}
```

- [ ] **Step 1: Write failing focus, pinning, and serialization tests**

Register two fake endpoints for one key and assert most-recent focus wins only while idle. Starting a turn pins one endpoint; later focus does not migrate it. Closing the pinned endpoint emits a pin-loss event. Assert one key serializes calls while different keys execute concurrently.

- [ ] **Step 2: Write failing observe/guard/approve/act/wait router tests**

Script fake frames and receipts. Verify all six tools, stale revision rejection, exact approval suspension, denial, interrupt cancellation, journal-before-action order, no automatic replay after a failed PTY receipt, and no hidden endpoint use. Verify a second input batch waits for the first acknowledgement. Verify route change after approval returns `approvalExpired`.

- [ ] **Step 3: Write failing temporary-pane lifecycle tests**

On create, record origin, split, require the new pane to be active, publish a new screen, and journal the lease. On finish, run this fixed visible shell probe through `TerminalSessionPort` only when the current command is a known shell (`bash`, `zsh`, `sh`, `fish` with a shell-specific equivalent):

Use lease-specific short markers and a command short enough not to wrap at the verified terminal width, for example nonce `7F3A` yields the shell-equivalent of `b=B7F3A;e=E7F3A;printf '\n%s\n' $b;jobs -p;printf '%s\n' $e`. Parse the last exact whole-line begin/end markers; marker text embedded in the shell's echoed command line does not count. If the width cannot keep the probe unwrapped, retain the pane as uncertain.

Close only if the stable returned screen has the exact output marker pair with no job IDs and the route still names the lease pane. Retain for foreground process, nonempty jobs, unsupported shell, marker ambiguity, timeout, disconnect, revision drift, or user surface switch. Permit at most one live lease per turn. Interruption/crash never runs the probe or auto-closes a lease; it retains the pane and journals the reason. Journal and return every close/retain result.

- [ ] **Step 4: Run RED, then implement the registry/router**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Terminal endpoint|Terminal tool router'`

Make `TerminalEndpointRegistry` an actor holding `Sendable` terminal/surface ports. `TerminalToolRouter.beginTurn` pins by thread + conversation before `turn/start`; the first matching app-server `turnId` may claim the prepared binding, and `confirmTurnID` must match it. This prevents a Dynamic Tool request racing the `turn/start` response from becoming unrouteable. Steering keeps the same binding. `endTurn`/interrupt cancels waiters, approvals, unsent batches, and releases the endpoint.

For every mutating call: observe/verify route and revision, append request, evaluate policy, await exact approval if required, append decision, execute once, await receipt/screen, append result. Never derive a port from tab selection after the turn is pinned.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCore/TerminalEndpointRegistry.swift \
  Sources/MerlinLizdCore/TerminalTool.swift \
  Sources/MerlinLizdCore/TerminalToolRouter.swift \
  Tests/MerlinLizdCoreTests/TerminalEndpointRegistryTests.swift \
  Tests/MerlinLizdCoreTests/TerminalToolRouterTests.swift \
  Tests/MerlinLizdCoreTests/TerminalToolTestSupport.swift
git commit -m "feat: route codex through pinned terminals"
```

### Task 6: Bridge SwiftTerm Rendering and Acknowledged PTY Input

**Files:**
- Modify: `Package.swift`
- Create: `Vendor/SwiftTerm/MERLINHUB_PATCHES.md`
- Modify: `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift:944-1018`
- Modify: `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:215-241`
- Create: `Sources/MerlinLizdApp/AgentTerminalView.swift`
- Create: `Sources/MerlinLizdApp/SwiftTermTerminalDriver.swift`
- Modify: `Sources/MerlinLizdApp/TerminalSession.swift:8-75`
- Modify: `Sources/MerlinLizdApp/TerminalSessionHost.swift`
- Create: `Tests/MerlinLizdCoreTests/SwiftTermFrameFixtureTests.swift`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/TerminalFrames/shell.json`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/TerminalFrames/vim.json`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/TerminalFrames/menu.json`

**Interfaces:**

```swift
@MainActor
final class AgentTerminalView: LocalProcessTerminalView {
    var keyboardOwner: TerminalKeyboardOwner
    var onRenderedFrame: ((TerminalGridFrame) -> Void)?
    func sendAgentBytes(_ bytes: [UInt8]) async throws
}

@MainActor
final class SwiftTermTerminalDriver: TerminalSessionPort {
    // wraps AgentTerminalView + TerminalScreenChannel
}
```

- [ ] **Step 1: Add failing fixture-based terminal-loop tests**

Store Core `TerminalGridFrame` fixtures (not ANSI output) for shell, Vim alternate screen, and a highlighted menu. Add `.copy("Fixtures")` to the existing custom test executable target and load them with `Bundle.module`. Feed them through the reducer/channel and verify cursor, mode, inverse/selected ranges, semantic key bytes, revision changes, stability, and stale rejection. These tests remain independent of AppKit.

- [ ] **Step 2: Add the two intentional SwiftTerm embedding hooks**

Document both in `MERLINHUB_PATCHES.md`:

1. Make the existing row selection range query public/read-only so the embedder can mark selected rendered cells without exposing mutation.
2. Add a `LocalProcess.send(data:completion:)` overload whose completion fires exactly once after `DispatchIO.write` reports all bytes accepted, or reports the POSIX error. Keep the existing `send(data:)` source-compatible by delegating and ignoring completion.

Do not change rendering, keyboard mapping, process launch, or package resource behavior.

- [ ] **Step 3: Implement `AgentTerminalView` on the main queue**

Override `dataReceived`, call `super` first, then synchronously copy the visible `terminal.buffer` rows, cursor, dimensions, `isCurrentBufferAlternate`, application-cursor mode, `CharData` styles, and public selection ranges into an immutable `TerminalGridFrame`. Publish after escape-sequence processing; never retain SwiftTerm buffers across calls.

Override terminal delegate `send(source:data:)`: forward to `super` only when the owner is `.user`. This blocks typing but leaves scroll/selection/copy intact. `sendAgentBytes` bypasses the user delegate and uses the acknowledged LocalProcess overload. Check `process.running` before submission and bridge completion to async/await.

- [ ] **Step 4: Integrate the driver with `TerminalSession`**

Replace the concrete view construction with `AgentTerminalView`, create one driver/channel per session, expose keyboard ownership, and publish disconnect/close to the driver so waits and input fail promptly. The terminal still starts the same managed SSH/tmux command. Removing a SwiftUI host must not close the session. Closing a tab continues to use the existing explicit `close()` lifecycle.

- [ ] **Step 5: Run GREEN, build, and commit**

Run: `./scripts/test.sh`

Run: `/usr/bin/swift build`

```bash
git add Package.swift \
  Vendor/SwiftTerm/MERLINHUB_PATCHES.md \
  Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift \
  Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift \
  Sources/MerlinLizdApp/AgentTerminalView.swift \
  Sources/MerlinLizdApp/SwiftTermTerminalDriver.swift \
  Sources/MerlinLizdApp/TerminalSession.swift \
  Sources/MerlinLizdApp/TerminalSessionHost.swift \
  Tests/MerlinLizdCoreTests/SwiftTermFrameFixtureTests.swift \
  Tests/MerlinLizdCoreTests/Fixtures/TerminalFrames
git commit -m "feat: bridge codex to rendered terminals"
```

### Task 7: Create the Replaceable Agent Client and JSONL Transport

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MerlinLizdCore/CodexAgentClient.swift`
- Create: `Sources/MerlinLizdCodexAdapter/CodexVersion.swift`
- Create: `Sources/MerlinLizdCodexAdapter/CodexExecutableResolver.swift`
- Create: `Sources/MerlinLizdCodexAdapter/AppServerProcess.swift`
- Create: `Sources/MerlinLizdCodexAdapter/JSONLAppServerTransport.swift`
- Create: `Sources/MerlinLizdCodexAdapter/CodexAppServerWire.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexVersionTests.swift`
- Create: `Tests/MerlinLizdCoreTests/JSONLAppServerTransportTests.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexAppServerTestSupport.swift`

**Package changes:**

```swift
.target(
    name: "MerlinLizdCodexAdapter",
    dependencies: ["MerlinLizdCore"]
)
// Add MerlinLizdCodexAdapter to App and MerlinLizdCoreTests dependencies;
// preserve the test target's `.copy("Fixtures")` resource declaration.
```

**Core protocol:**

```swift
public enum AgentAvailability: Equatable, Sendable {
    case ready, starting
    case unsupportedVersion(String)
    case authenticationRequired
    case capabilityUnavailable(String)
    case overloaded, crashed, stopped
}

public protocol CodexAgentClient: Sendable {
    func startThread() async throws -> AgentThreadID
    func resumeThread(_ threadID: AgentThreadID) async throws
    func startTurn(threadID: AgentThreadID, prompt: String) async throws -> AgentTurnID
    func steerTurn(threadID: AgentThreadID, turnID: AgentTurnID, prompt: String) async throws
    func interruptTurn(threadID: AgentThreadID, turnID: AgentTurnID) async
    func events(for threadID: AgentThreadID) async -> AsyncStream<AgentEvent>
    func availability() async -> AsyncStream<AgentAvailability>
    func archiveThread(_ threadID: AgentThreadID) async throws
    func unarchiveThread(_ threadID: AgentThreadID) async throws
    func deleteThread(_ threadID: AgentThreadID) async throws
    func shutdown() async
}
```

- [ ] **Step 1: Write failing semantic-version and resolver tests**

Parse `codex-cli 0.144.2`, reject malformed output, and accept only `[0.144.2, 0.145.0)`. Resolver order is an explicit test override, `/Applications/ChatGPT.app/Contents/Resources/codex`, user `PATH`, `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`. The override is for tests/development only and is not an API-key/config requirement. Version probing has a two-second timeout.

- [ ] **Step 2: Write failing transport tests**

Use a scripted in-memory process. Cover integer/string JSON-RPC IDs, concurrent pending requests, response correlation, notifications, server requests, unknown additive fields, unknown notifications, unknown server requests returning method-not-found, malformed JSON, a 4 MiB line cap, bounded 64 KiB stderr tail, EOF/process crash failing every continuation, and cancellation. No fixture may launch the real binary.

- [ ] **Step 3: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Codex version|app-server transport'`

- [ ] **Step 4: Implement the adapter target and tolerant transport**

Define only the wire shapes used by V1 plus a recursive `JSONValue`; do not check in the full generated schema. `AppServerProcess` owns `Foundation.Process`, stdin/stdout/stderr pipes, termination, and reap. `JSONLAppServerTransport` is an actor with monotonic request IDs and an `AsyncStream` of decoded server messages. Unknown notification methods are ignored by the adapter; unknown requests receive JSON-RPC `-32601` and never reach Core. Raw payloads and auth state must not be logged.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Package.swift \
  Sources/MerlinLizdCore/CodexAgentClient.swift \
  Sources/MerlinLizdCodexAdapter \
  Tests/MerlinLizdCoreTests/CodexVersionTests.swift \
  Tests/MerlinLizdCoreTests/JSONLAppServerTransportTests.swift \
  Tests/MerlinLizdCoreTests/CodexAppServerTestSupport.swift
git commit -m "feat: add codex app-server transport"
```

### Task 8: Adapt Dynamic Tools and Contain Codex Capabilities

**Files:**
- Create: `Sources/MerlinLizdCodexAdapter/CodexLaunchConfiguration.swift`
- Create: `Sources/MerlinLizdCodexAdapter/CodexDynamicTools.swift`
- Create: `Sources/MerlinLizdCodexAdapter/CodexAppServerAdapter.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexLaunchConfigurationTests.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexDynamicToolsTests.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexAppServerContractTests.swift`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/README.md`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/initialize.jsonl`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/thread-start-resume.jsonl`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/turn-stream.jsonl`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/dynamic-tools.jsonl`
- Create: `Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer/errors.jsonl`

- [ ] **Step 1: Check in minimal 0.144.2 contract fixtures and failing tests**

Document that fixtures were selected from:

```bash
codex app-server generate-json-schema --out /tmp/merlinhub-codex-schema-01442 --experimental
```

Test required shapes for `initialize`, `thread/start`, `thread/resume`, `thread/archive`, `thread/unarchive`, `thread/delete`, `turn/start`, `turn/steer`, `turn/interrupt`, `item/agentMessage/delta`, `turn/completed`, and `item/tool/call`. Test Dynamic Tool request fields `arguments`, `callId`, `threadId`, `tool`, `turnId`, optional `namespace`, and response `{contentItems:[{type:"inputText",text}],success}`. Add unknown notification, overload, malformed critical field, unauthorized, and process crash fixtures.

- [ ] **Step 2: Write failing isolation/launch tests**

Assert launch arguments contain `app-server`, clear configured MCP servers, and explicitly disable `shell_tool`, `unified_exec`, `apply_patch_freeform`, `web_search`, `apps`, `image_generation`, `browser_use`, `computer_use`, `multi_agent`, `js_repl`, `code_mode`, `tool_search`, `connectors`, and `plugins`. The process inherits `CODEX_HOME` and auth environment unchanged and never receives an API-key argument.

Assert `thread/start` sends:

```json
{
  "approvalPolicy": "never",
  "cwd": "${runtimeDirectory}",
  "sandbox": "read-only",
  "environments": [],
  "runtimeWorkspaceRoots": [],
  "selectedCapabilityRoots": [],
  "ephemeral": false,
  "dynamicTools": [{"type":"namespace","name":"merlin_tmux","tools":[]}]
}
```

Do not set `model`; existing local model configuration wins. `initialize` must set `capabilities.experimentalApi=true` and validate `codexHome`, `platformFamily`, `platformOs`, and `userAgent`.

- [ ] **Step 3: Define exactly six namespaced Dynamic Tools**

Generate JSON schemas by hand from Core value types for `observe_screen`, `send_input`, `wait_for_screen`, `select_visible_surface`, `create_temporary_pane`, and `finish_temporary_pane`. Tool descriptions must state: current visible pane only, observe before acting, expected revision required for mutation, wait instead of fixed sleep, no hidden pane reads, and approval may pause execution. Reject an unrecognized namespace/tool before calling the router.

- [ ] **Step 4: Implement the adapter mapping**

Map app-server threads/turns/messages/status/errors into `AgentThreadID`, `AgentTurnID`, and `AgentEvent`. Convert the turns/items returned by `thread/resume` into initial history events before streaming new deltas, so a relaunched drawer shows the persistent conversation. Map only `merlin_tmux` calls into `TerminalToolCall`, call `TerminalToolRouter`, encode its protocol-neutral result as `inputText`, and echo no raw Swift error. The router's prepared turn binding handles a Dynamic Tool call that races the `turn/start` continuation.

For 0.144.2, `thread/resume` deliberately omits `dynamicTools` because the schema does not accept it. Resume only IDs in the local mapping store created by this adapter; the original thread start supplied the tools. Contract-test a resumed thread emitting a `merlin_tmux` call. Any built-in tool/server request remains disabled/rejected.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCodexAdapter/CodexLaunchConfiguration.swift \
  Sources/MerlinLizdCodexAdapter/CodexDynamicTools.swift \
  Sources/MerlinLizdCodexAdapter/CodexAppServerAdapter.swift \
  Tests/MerlinLizdCoreTests/CodexLaunchConfigurationTests.swift \
  Tests/MerlinLizdCoreTests/CodexDynamicToolsTests.swift \
  Tests/MerlinLizdCoreTests/CodexAppServerContractTests.swift \
  Tests/MerlinLizdCoreTests/Fixtures/CodexAppServer
git commit -m "feat: expose guarded tmux tools to codex"
```

### Task 9: Persist Conversations and Coordinate Independent Turns

**Files:**
- Create: `Sources/MerlinLizdCore/CodexConversationStore.swift`
- Create: `Sources/MerlinLizdCore/CodexSessionCoordinator.swift`
- Create: `Sources/MerlinLizdCore/CodexSessionState.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexConversationStoreTests.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexSessionCoordinatorTests.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexSessionTestSupport.swift`

**Interfaces:**

```swift
public enum CodexSessionPhase: Codable, Equatable, Sendable {
    case idle, thinking, controlling, awaitingApproval, waitingForUser
    case completed, failed(CodexFailure), interrupted
}

public struct CodexConversationRecord: Codable, Equatable, Sendable {
    public let key: TerminalConversationKey
    public var threadID: AgentThreadID
    public let protocolGeneration: String  // "app-server-0.144"
    public var archived: Bool
    public var updatedAt: Date
}

public actor CodexSessionCoordinator {
    public func registerEndpoint(...)
    public func focusEndpoint(...)
    public func submit(_ prompt: String, for key: TerminalConversationKey) async
    public func approve(_ requestID: UUID) async
    public func deny(_ requestID: UUID) async
    public func stopAndTakeOver(_ key: TerminalConversationKey) async
    public func deleteConversation(_ key: TerminalConversationKey) async throws
    public func states() -> AsyncStream<[TerminalConversationKey: CodexSessionState]>
}
```

- [ ] **Step 1: Write failing mapping and deletion tests**

Assert one key resumes one thread across launches and matching tabs; rename retains the mapping; same-name recreation starts a new thread; different keys get distinct threads. Persist atomically under the same user-only Application Support root. Archive/unarchive calls the matching agent-client method while preserving mapping and journal. Delete first requires the caller's separately confirmed intent, then calls `deleteThread`, removes mapping and journal; partial failure is recorded as a retryable tombstone rather than silently losing references.

- [ ] **Step 2: Write failing turn/steer/concurrency tests**

With a fake `CodexAgentClient`, assert an idle submit resolves identity, selects and pins the most recent endpoint, transfers keyboard ownership, prepares router binding, and starts a turn. A second submit while active calls steer with the exact active turn. Same-key starts serialize; different keys can both be active. Completion releases the pin/keyboard. Pinned-tab closure interrupts rather than migrates. PTY disconnect interrupts only that key. Stop cancels approvals/waits/unsent batches and calls `turn/interrupt` but sends no terminal bytes.

- [ ] **Step 3: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Codex conversation store|Codex session coordinator'`

- [ ] **Step 4: Implement state/event reduction**

Make the coordinator an actor keyed by `TerminalConversationKey`; never use one global current conversation. Start/resume threads lazily. Consume each thread's `AgentEvent` stream into protocol-neutral message/tool history. Map phases exactly and expose immutable snapshots to UI. Pin before `startTurn`, confirm the returned turn ID, and unwind pin/ownership on every error/cancellation path. Steering does not repin. A background approval changes only its key and emits an approval event for App notification handling.

- [ ] **Step 5: Run GREEN and commit**

Run: `./scripts/test.sh`

```bash
git add Sources/MerlinLizdCore/CodexConversationStore.swift \
  Sources/MerlinLizdCore/CodexSessionCoordinator.swift \
  Sources/MerlinLizdCore/CodexSessionState.swift \
  Tests/MerlinLizdCoreTests/CodexConversationStoreTests.swift \
  Tests/MerlinLizdCoreTests/CodexSessionCoordinatorTests.swift \
  Tests/MerlinLizdCoreTests/CodexSessionTestSupport.swift
git commit -m "feat: coordinate persistent codex sessions"
```

### Task 10: Supervise app-server and Integrate App Lifecycle

**Files:**
- Create: `Sources/MerlinLizdCodexAdapter/CodexAppServerSupervisor.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexAppServerSupervisorTests.swift`
- Create: `Sources/MerlinLizdApp/CodexRuntime.swift`
- Modify: `Sources/MerlinLizdApp/MerlinRemoteRuntime.swift`
- Modify: `Sources/MerlinLizdApp/MerlinLizdApplication.swift`
- Modify: `Sources/MerlinLizdApp/TerminalTabsModel.swift`
- Create: `Sources/MerlinLizdApp/CodexNotificationController.swift`

- [ ] **Step 1: Write failing supervisor tests**

With a scripted process factory, assert startup/version/initialize success; unsupported version/auth/capability failure disables only Codex; crash fails active requests, marks active turns interrupted, and uses exponential restart delays `1, 2, 4, 8, 16, 30` seconds capped at 30. After restart, mapped idle threads resume. No active turn, Dynamic Tool request, or terminal input is replayed. Explicit shutdown cancels backoff, interrupts turns, closes stdin, terminates/reaps the child, and returns.

- [ ] **Step 2: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Codex app-server supervisor'`

- [ ] **Step 3: Implement one process-wide supervised adapter**

The supervisor owns one adapter process shared by all conversations, starts lazily when a tmux drawer needs it, and publishes protocol-neutral `AgentAvailability` values (`ready`, `unsupportedVersion`, `authenticationRequired`, `capabilityUnavailable`, `overloaded`, `crashed`, `stopped`). Backoff is cancellation-aware and injectable for tests. Never include stderr/raw JSON in user-visible text; map to bounded diagnostics.

- [ ] **Step 4: Compose App ports and lifecycle**

`CodexRuntime` creates the Application Support root, journal/store, approval broker, endpoint registry, router, supervisor/client, and coordinator. Inject the existing `TmuxSessionController`. `TerminalTabsModel.session(for:)` registers a `SwiftTermTerminalDriver` only after `tmuxIdentity` resolves; selected/focused tabs update endpoint focus. Closing a session unregisters it and triggers pin loss. App shutdown awaits the Codex runtime before the existing SSH/tmux runtime shutdown; neither path kills remote tmux.

Send a macOS notification only when an approval belongs to a background conversation. Do not select its tab automatically. Notification click may select the matching tab/drawer but must not approve.

- [ ] **Step 5: Run GREEN, build, and commit**

Run: `./scripts/test.sh`

Run: `/usr/bin/swift build`

```bash
git add Sources/MerlinLizdCodexAdapter/CodexAppServerSupervisor.swift \
  Tests/MerlinLizdCoreTests/CodexAppServerSupervisorTests.swift \
  Sources/MerlinLizdApp/CodexRuntime.swift \
  Sources/MerlinLizdApp/CodexNotificationController.swift \
  Sources/MerlinLizdApp/MerlinRemoteRuntime.swift \
  Sources/MerlinLizdApp/MerlinLizdApplication.swift \
  Sources/MerlinLizdApp/TerminalTabsModel.swift
git commit -m "feat: integrate codex runtime lifecycle"
```

### Task 11: Build the Bottom Drawer, Shared Badges, and Takeover UI

**Files:**
- Create: `Sources/MerlinLizdCore/CodexDrawerState.swift`
- Create: `Tests/MerlinLizdCoreTests/CodexDrawerStateTests.swift`
- Create: `Sources/MerlinLizdApp/CodexDrawerModel.swift`
- Create: `Sources/MerlinLizdApp/CodexDrawerView.swift`
- Create: `Sources/MerlinLizdApp/CodexApprovalCardView.swift`
- Create: `Sources/MerlinLizdApp/CodexOperationView.swift`
- Modify: `Sources/MerlinLizdApp/TerminalWorkspaceView.swift:1-55`
- Modify: `Sources/MerlinLizdApp/TerminalWorkspaceView.swift:55-220`
- Modify: `Sources/MerlinLizdApp/MerlinRootView.swift`

- [ ] **Step 1: Write failing drawer reducer tests**

Cover collapsed `42`, active compact `92`, and expanded/resizable `20...50%` states; prompt submit, steering, takeover, approval allow/deny, background badge aggregation, shared badges for matching tabs, retryable availability errors, disconnected terminal state, unresolved tmux identity, and plain local shell exclusion. Verify a takeover action restores keyboard only after coordinator interruption/cancellation completes.

- [ ] **Step 2: Run RED**

Run: `/usr/bin/swift run MerlinLizdCoreTests --filter 'Codex drawer state'`

- [ ] **Step 3: Implement a pure drawer state reducer and App model**

Keep layout state and action enablement in Core; App model subscribes to coordinator snapshots. Scope the composer/history to the selected conversation key. Show the current action and steer composer while active. Expose exact approval payload, reason, endpoint/surface, screen revision/context, and only **Allow Once** / **Deny**. Summarize tool activity by default with expandable journal details.

- [ ] **Step 4: Compose the terminal and drawer UI**

Place a vertical stack in `TerminalWorkspaceView`: terminal consumes remaining height; drawer is bottom-aligned. Collapsed idle drawer preserves terminal space at 42 points; active phase automatically reaches at least compact; expanded height uses a drag handle and clamps to 20...50% of container. Continue rendering background terminal sessions and their process output even when not selected.

Add per-tab phase/approval badges based on conversation key, not tab ID. Matching tabs show identical state. Other running conversations retain their own badges. **Stop and Take Over** calls only the coordinator API; no key event or process termination is attached to the button.

- [ ] **Step 5: Run GREEN, build, and commit**

Run: `./scripts/test.sh`

Run: `/usr/bin/swift build`

```bash
git add Sources/MerlinLizdCore/CodexDrawerState.swift \
  Tests/MerlinLizdCoreTests/CodexDrawerStateTests.swift \
  Sources/MerlinLizdApp/CodexDrawerModel.swift \
  Sources/MerlinLizdApp/CodexDrawerView.swift \
  Sources/MerlinLizdApp/CodexApprovalCardView.swift \
  Sources/MerlinLizdApp/CodexOperationView.swift \
  Sources/MerlinLizdApp/TerminalWorkspaceView.swift \
  Sources/MerlinLizdApp/MerlinRootView.swift
git commit -m "feat: add tmux codex drawer"
```

### Task 12: Close Failure Gaps and Verify End-to-End Invariants

**Files:**
- Create: `Tests/MerlinLizdCoreTests/CodexTerminalAcceptanceTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/ConcurrencyRegressionTests.swift`
- Modify: `README.md:89-335`
- Modify: `Docs/SPEC.md`
- Modify: `scripts/package-app.sh` only if adapter/runtime resources require explicit packaging

- [ ] **Step 1: Write cross-layer acceptance tests with fakes**

Build an in-memory harness using fake agent client, endpoint registry, terminal/surface ports, permission policy, and real file journal/store. Cover:

1. shell observe -> routine input -> acknowledged receipt -> stable screen;
2. Vim alternate screen -> semantic navigation -> stale revision -> re-observe;
3. destructive prompt -> background approval -> route change -> expired approval;
4. temporary pane create -> visible jobs probe -> safe close/restore;
5. temporary pane with job/uncertainty -> retain and report;
6. two conversations active concurrently while one key remains serialized;
7. same session in two tabs shares messages/badges and pins one endpoint;
8. pinned tab closes -> interrupt with zero Control-C/kill bytes;
9. app-server/PTY/SSH crash -> one interrupted key, no replay, remote session untouched;
10. journal/store reopen and separately confirmed delete semantics.

Add a concurrency regression with many screen publications, waits, interrupts, and endpoint closes to prove no leaked continuations or cross-key action.

- [ ] **Step 2: Run the complete automated suite and fix only root causes**

Run: `./scripts/test.sh`

Run: `/usr/bin/swift build`

Expected: all tests and all package targets pass under Swift 6 concurrency checking. No test launches real Merlin, SSH, tmux, Codex, or a network request.

- [ ] **Step 3: Audit the containment and mutation paths**

Use `rg` to verify:

- only `CodexDynamicTools` contains app-server Dynamic Tool schema names;
- only `SwiftTermTerminalDriver`/`AgentTerminalView` sends agent PTY bytes;
- every router mutation calls permission and journal before a port/controller;
- no `capture-pane`, arbitrary shell API, API-key field, remote filesystem mount, or hidden-pane reader exists;
- Stop/interrupt paths contain no `0x03`, `kill-pane`, `kill-session`, or terminal close;
- all `TerminalConversationKey` creation requires a non-optional tmux identity.

- [ ] **Step 4: Run a deliberate manual smoke test**

Launch: `/usr/bin/swift run MerlinHub`

Using a disposable local tmux session (not production work), verify collapsed/compact/expanded layout, shell typing ownership, scroll/copy during Codex control, takeover without process interruption, Vim/menu navigation, session rename continuity, two parallel session badges, background approval notification, temporary-pane retain/close behavior, and graceful app-server-unavailable UI. Do not test destructive approvals against valuable data.

- [ ] **Step 5: Update compatibility/operations docs and package**

Update README implementation status with the exact supported Codex range, local-auth reuse, Application Support/journal sensitivity, delete semantics, and troubleshooting states. Update `Docs/SPEC.md` vocabulary if it still describes only terminal tabs. If the new adapter target adds no resources, leave packaging unchanged; otherwise add only the required resource copy and validate signing.

Run: `./scripts/package-app.sh`

Expected: `dist/MerlinHub.app` is produced and strict signature validation in the script passes.

- [ ] **Step 6: Final verification and commit**

Run: `./scripts/test.sh`

Run: `/usr/bin/swift build`

```bash
git add Tests/MerlinLizdCoreTests/CodexTerminalAcceptanceTests.swift \
  Tests/MerlinLizdCoreTests/ConcurrencyRegressionTests.swift \
  README.md Docs/SPEC.md
if ! git diff --quiet -- scripts/package-app.sh; then
  git add scripts/package-app.sh
fi
git commit -m "test: verify tmux codex workflow"
```

## Completion Criteria

- A tmux-backed tab with a resolved stable identity can start/resume a local Codex conversation without API-key setup.
- Every Codex terminal mutation passes expected-revision validation, deterministic permission policy, exact one-time approval when high-risk, and durable journal-before-action ordering.
- Codex can control shell and alternate-screen TUI input through the active rendered SwiftTerm surface, while user typing is locked and scroll/copy remain available.
- Switching surfaces is visible; no hidden-pane content is read or mutated. Temporary panes close only with visible idle proof and otherwise remain.
- Matching tabs share a persistent conversation; different sessions run independently; active endpoints never migrate mid-turn.
- Takeover, disconnect, crash, and app shutdown interrupt local agent work without Control-C, replay, or remote tmux termination.
- `./scripts/test.sh`, `/usr/bin/swift build`, and `./scripts/package-app.sh` pass.
