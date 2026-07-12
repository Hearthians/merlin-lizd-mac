# SSH Connection Reuse and tmux Prewarming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse one App-owned OpenSSH master per running Devbox and prewarm Worker tmux snapshots at App launch so cached session lists open immediately without changing remote tmux lifecycle.

**Architecture:** `SSHMasterPool` is the sole owner of control sockets, preparation, retry, and graceful shutdown. Existing Core clients receive the pool explicitly and route remote reads, mutations, streams, and terminal commands through it. `TargetWarmupCoordinator` consumes safe inventory snapshots, schedules prioritized read-only tmux probes with at most two Worker logins, and stores timestamped snapshots in `TmuxSessionDiscovery` for stale-while-revalidate UI rendering.

**Tech Stack:** Swift 6, Swift Concurrency actors/tasks, Foundation `Process` infrastructure already in `InventoryProcess.swift`, OpenSSH ControlMaster, SwiftUI, Swift Testing.

## Global Constraints

- macOS deployment target remains macOS 14; add no package dependency.
- Do not edit `~/.ssh/config` or log `ssh -G`, ProxyCommand, credentials, or Merlin tokens.
- Control sockets must live in a short App-owned directory with mode `0700`; socket filenames must be hashed aliases.
- Use `ControlMaster=auto`, the App-owned `ControlPath`, and `ControlPersist=600` on child channels.
- Prewarming begins from cached inventory when the App opens and never blocks the first UI frame.
- Prewarm every current Worker, selected/open/recent targets first, with at most two Worker logins at once.
- Every warmup command is fixed and read-only; it must never create, attach, rename, or kill tmux sessions or change Worker lifecycle.
- A successful no-server/no-sessions response means a ready Worker with an authoritative empty session list; a not-ready response is not an empty authoritative inventory.
- Snapshots are fresh for 60 seconds, revalidated after 60 seconds, periodically refreshed every five minutes, and retained as last-known evidence after failures.
- Read-only commands may retry once after rebuilding a dead master; mutation commands must never be replayed automatically.
- Closing a terminal or the App leaves remote tmux sessions running; normal App shutdown uses `ssh -O stop` and lets existing channels drain.
- Preserve all pre-existing working-tree changes. Before each commit, inspect `git diff --cached --name-only`; never use `git add -A`.

## File Structure

- Create `Sources/MerlinLizdCore/SSHMasterCommands.swift`: pure validation, hashed socket paths, and exact OpenSSH argv construction.
- Create `Sources/MerlinLizdCore/SSHMasterPool.swift`: connection lifecycle, single-flight preparation, priority queueing, read retry, and graceful shutdown.
- Create `Sources/MerlinLizdCore/TargetWarmupCoordinator.swift`: inventory reconciliation, Worker priority ordering, generation cancellation, periodic refresh, and update callbacks.
- Modify `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift`: public timestamped snapshot model, single-flight refresh, readiness evidence, and stale-while-revalidate cache.
- Modify `Sources/MerlinLizdCore/TmuxSessionController.swift`: run mutations through the shared pool with replay disabled.
- Modify `Sources/MerlinLizdCore/MerlinCommands.swift`: add one combined Worker readiness/tmux command and expose the validated SSH alias for a `TerminalTarget`.
- Modify `Sources/MerlinLizdCore/MerlinInventory.swift`: share the pool for SSH fallback/readiness operations while leaving local `ssh -G` resolution unchanged.
- Modify `Sources/MerlinLizdCore/WorkerMetricsStreamer.swift`: prepare and decorate the long-lived metrics channel through the pool.
- Create `Sources/MerlinLizdApp/MerlinRemoteRuntime.swift`: one App-owned composition root for the pool, discovery, controller, streamer, and coordinator.
- Modify `Sources/MerlinLizdApp/AppModel.swift`: launch cached-inventory warmup, reconcile fresh inventory, and merge Worker readiness updates.
- Modify `Sources/MerlinLizdApp/TerminalTabsModel.swift`: use runtime-owned services, managed terminal commands, and foreground target prioritization.
- Modify `Sources/MerlinLizdApp/WorkerMonitoringModel.swift`: receive the runtime-owned metrics streamer.
- Modify `Sources/MerlinLizdApp/MachineViews.swift` and `Sources/MerlinLizdApp/MerlinRootView.swift`: pass the shared metrics streamer and foreground-priority signals without changing layout.
- Modify `Sources/MerlinLizdApp/TmuxSessionBrowserView.swift`: render cached snapshots before background verification and display timestamp/stale/error state.
- Modify `Sources/MerlinLizdApp/MerlinLizdApplication.swift`: construct the shared runtime and await its shutdown.
- Create `Tests/MerlinLizdCoreTests/SSHMasterCommandsTests.swift`, `SSHMasterPoolTests.swift`, and `TargetWarmupCoordinatorTests.swift`.
- Modify `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift`, `CommandBuilderTests.swift`, `MerlinInventoryTests.swift`, and `WorkerMetricsStreamerTests.swift`.
- Modify `README.md` and `Docs/SPEC.md`: document startup prewarming, cache semantics, and the remaining first Worker terminal limitation.

---

### Task 1: Safe OpenSSH command construction

**Files:**
- Create: `Sources/MerlinLizdCore/SSHMasterCommands.swift`
- Create: `Tests/MerlinLizdCoreTests/SSHMasterCommandsTests.swift`

**Interfaces:**
- Consumes: `CommandSpec`, `MerlinIdentifierValidator.isSSHAlias(_:)`.
- Produces: `SSHMasterCommands.init(directory:)`, `socketPath(alias:)`, `prepare(alias:)`, `check(alias:)`, `stop(alias:)`, and `managed(_:alias:)`.

- [ ] **Step 1: Write failing tests for path privacy, stable hashing, and argv placement**

```swift
import Foundation
import Testing
@testable import MerlinLizdCore

@Suite("SSH master commands")
struct SSHMasterCommandsTests {
    @Test("uses a stable hashed socket path without exposing the alias")
    func hashesAlias() throws {
        let root = URL(fileURLWithPath: "/tmp/mlz-tests", isDirectory: true)
        let commands = SSHMasterCommands(directory: root)
        let first = try commands.socketPath(alias: "hl_gpu_2")
        #expect(first == try commands.socketPath(alias: "hl_gpu_2"))
        #expect(first.hasPrefix("/tmp/mlz-tests/m-"))
        #expect(!first.contains("hl_gpu_2"))
        #expect(first.utf8.count < 104)
    }

    @Test("builds prepare check and graceful stop commands")
    func lifecycleCommands() throws {
        let commands = SSHMasterCommands(
            directory: URL(fileURLWithPath: "/tmp/mlz-tests")
        )
        let prepare = try commands.prepare(alias: "hl_gpu_2")
        #expect(prepare.executable == "/usr/bin/ssh")
        #expect(prepare.arguments.contains("ControlMaster=yes"))
        #expect(prepare.arguments.contains("ControlPersist=600"))
        #expect(prepare.arguments.suffix(1) == ["hl_gpu_2"])
        #expect(try commands.check(alias: "hl_gpu_2").arguments.contains("check"))
        #expect(try commands.stop(alias: "hl_gpu_2").arguments.contains("stop"))
    }

    @Test("inserts multiplexing options before the validated destination")
    func decoratesChild() throws {
        let commands = SSHMasterCommands(
            directory: URL(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "tmux list-sessions"]
        )
        let managed = try commands.managed(child, alias: "hl_gpu_2")
        let aliasIndex = try #require(managed.arguments.firstIndex(of: "hl_gpu_2"))
        #expect(managed.arguments[..<aliasIndex].contains("ControlMaster=auto"))
        #expect(managed.arguments[..<aliasIndex].contains("ControlPersist=600"))
        #expect(managed.arguments.last == "tmux list-sessions")
    }
}
```

- [ ] **Step 2: Run the suite and verify the new symbols are missing**

Run: `swift run MerlinLizdCoreTests --filter 'SSH master commands'`

Expected: build failure containing `cannot find 'SSHMasterCommands' in scope`.

- [ ] **Step 3: Implement the pure command builder**

Create an internal `SSHMasterCommands` value type. Use `CryptoKit.SHA256` over the validated alias and keep the first 24 lowercase hex characters. `managed` must reject a non-SSH executable or a command that does not contain the exact validated alias as an argv element; insert these six argv elements immediately before that destination:

```swift
["-o", "ControlMaster=auto",
 "-o", "ControlPath=\(socketPath)",
 "-o", "ControlPersist=600"]
```

The lifecycle argv must be exactly:

```swift
// prepare
["-MNf", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
 "-o", "ControlMaster=yes", "-o", "ControlPath=\(socketPath)",
 "-o", "ControlPersist=600", alias]

// check / stop
["-O", operation, "-o", "BatchMode=yes",
 "-o", "ControlPath=\(socketPath)", alias]
```

Add `SSHMasterCommandError.invalidAlias`, `.invalidSSHCommand`, and `.socketPathTooLong`. Do not accept a caller-provided remote shell string in this type.

- [ ] **Step 4: Run focused and full Core tests**

Run: `swift run MerlinLizdCoreTests --filter 'SSH master commands'`

Expected: all three new tests pass.

Run: `swift run MerlinLizdCoreTests`

Expected: all existing tests pass.

- [ ] **Step 5: Commit the pure boundary**

```bash
git add Sources/MerlinLizdCore/SSHMasterCommands.swift Tests/MerlinLizdCoreTests/SSHMasterCommandsTests.swift
git diff --cached --check
git commit -m "feat: build safe SSH master commands"
```

### Task 2: App-owned SSH master lifecycle

**Files:**
- Create: `Sources/MerlinLizdCore/SSHMasterPool.swift`
- Create: `Tests/MerlinLizdCoreTests/SSHMasterPoolTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/ConcurrencyTestSupport.swift`

**Interfaces:**
- Consumes: `SSHMasterCommands`, `InventoryProcessRunning`, `FoundationInventoryProcessRunner`, `CommandSpec`.
- Produces:

```swift
public enum SSHWarmupPriority: Int, Sendable { case background, foreground }
public enum SSHReplayPolicy: Sendable { case readOnly, never }
public enum SSHLinkState: Equatable, Sendable { case ready, failed }
enum SSHMasterPoolError: Error, Equatable, Sendable { case commandFailed(exitCode: Int32), shuttingDown }

public final class SSHMasterPool: @unchecked Sendable {
    public init(maxConcurrentPreparations: Int = 4)
    public func prepare(alias: String, priority: SSHWarmupPriority) async -> SSHLinkState
    public func managedCommand(_ command: CommandSpec, alias: String) throws -> CommandSpec
    func run(_ command: CommandSpec, alias: String, replay: SSHReplayPolicy) async throws -> InventoryProcessOutput
    public func shutdown() async
}
```

- [ ] **Step 1: Add failing lifecycle and retry tests**

Cover these exact cases with a scripted actor runner that records `CommandSpec` values and can suspend selected calls:

Add this test-support surface beside the tests: `SSHMasterScriptedRunner.Action` has `.succeed`, `.exit(Int32)`, `.fail(SSHMasterTestError)`, and `.wait(AsyncStartGate, then: Action)`; `enqueue(_:)` appends actions; `commands()` returns recorded commands; and `count(argumentsContaining:)` counts argv substrings. Actions are consumed in FIFO order, with an empty queue defaulting to `.succeed`.

```swift
@Test("concurrent preparation for one alias launches one master")
func coalescesPreparation() async {
    let runner = SSHMasterScriptedRunner(prepareExitCodes: [0])
    let pool = SSHMasterPool(testDirectory: temporaryDirectory(), runner: runner)
    async let first = pool.prepare(alias: "hl_gpu_2", priority: .background)
    async let second = pool.prepare(alias: "hl_gpu_2", priority: .foreground)
    #expect(await [first, second] == [.ready, .ready])
    #expect(await runner.count(argumentsContaining: "ControlMaster=yes") == 1)
}

@Test("foreground preparation jumps queued background aliases")
func prioritizesForeground() async {
    let gate = AsyncStartGate()
    let runner = SSHMasterScriptedRunner(actions: [
        .exit(255), .wait(gate, then: .succeed),
        .exit(255), .succeed,
        .exit(255), .succeed,
    ])
    let pool = SSHMasterPool(
        testDirectory: temporaryDirectory(),
        runner: runner,
        maxConcurrentPreparations: 1
    )
    let first = Task { await pool.prepare(alias: "first", priority: .background) }
    await gate.waitUntilEntered()
    let background = Task { await pool.prepare(alias: "background", priority: .background) }
    let foreground = Task { await pool.prepare(alias: "foreground", priority: .foreground) }
    await gate.open()
    _ = await [first.value, foreground.value, background.value]
    let starts = await runner.masterStartAliases()
    #expect(starts == ["first", "foreground", "background"])
}

@Test("read-only command rebuilds once after dead-master transport failure")
func retriesReadOnce() async throws {
    let runner = SSHMasterScriptedRunner(actions: [
        .exit(255), .succeed, .exit(255), .exit(255), .succeed, .succeed,
    ])
    let pool = SSHMasterPool(testDirectory: temporaryDirectory(), runner: runner)
    let command = CommandSpec(
        executable: "/usr/bin/ssh",
        arguments: ["-nT", "hl_gpu_2", "tmux list-sessions"]
    )
    let output = try await pool.run(command, alias: "hl_gpu_2", replay: .readOnly)
    #expect(output.exitCode == 0)
    #expect(await runner.childCommandCount(alias: "hl_gpu_2") == 2)
}

@Test("mutation command is never replayed")
func neverReplaysMutation() async {
    let runner = SSHMasterScriptedRunner(actions: [.exit(255), .succeed, .exit(255)])
    let pool = SSHMasterPool(testDirectory: temporaryDirectory(), runner: runner)
    let command = CommandSpec(
        executable: "/usr/bin/ssh",
        arguments: ["-nT", "hl_gpu_2", "tmux kill-session -t train"]
    )
    await #expect(throws: SSHMasterPoolError.commandFailed(exitCode: 255)) {
        try await pool.run(command, alias: "hl_gpu_2", replay: .never)
    }
    #expect(await runner.childCommandCount(alias: "hl_gpu_2") == 1)
}

@Test("shutdown stops masters without issuing tmux commands")
func stopsGracefully() async {
    let runner = SSHMasterScriptedRunner(actions: [
        .exit(255), .succeed, .exit(255), .succeed,
        .succeed, .exit(255), .succeed, .exit(255),
    ])
    let pool = SSHMasterPool(testDirectory: temporaryDirectory(), runner: runner)
    #expect(await pool.prepare(alias: "hl_gpu_2", priority: .background) == .ready)
    #expect(await pool.prepare(alias: "lq_gpu", priority: .background) == .ready)
    await pool.shutdown()
    let commands = await runner.commands()
    #expect(commands.filter { $0.arguments.contains("stop") }.count == 2)
    #expect(!commands.contains { $0.arguments.contains(where: { $0.contains("tmux") }) })
}
```

Use the existing `AsyncStartGate` continuation pattern in `ConcurrencyTestSupport.swift`; make `masterStartAliases()` and `childCommandCount(alias:)` inspect exact argv positions rather than matching rendered shell strings.

- [ ] **Step 2: Run tests and verify lifecycle behavior is absent**

Run: `swift run MerlinLizdCoreTests --filter 'SSH master pool'`

Expected: build failure containing `cannot find 'SSHMasterPool' in scope`.

- [ ] **Step 3: Implement the pool and its priority limiter**

Use a private actor `SSHMasterPoolState` with:

```swift
private var readyAliases: Set<String> = []
private var preparations: [String: Task<SSHLinkState, Never>] = [:]
private var foregroundWaiters: [PreparationWaiter] = []
private var backgroundWaiters: [PreparationWaiter] = []
private var activePreparations = 0
private var isShuttingDown = false
```

Preparation must:

1. validate and create `$TMPDIR/mlz-ssh-<uid>` once with POSIX mode `0700` (tests inject a temporary directory);
2. return `.ready` if `ssh -O check` succeeds;
3. remove the socket only after `check` proves it abandoned;
4. run `prepare(alias:)` once per alias using a stored single-flight task;
5. serve foreground waiters before background waiters while respecting `maxConcurrentPreparations`;
6. record `.ready` only after a zero exit code.

`run` calls `prepare(alias:priority:.foreground)`, decorates the caller's already validated `CommandSpec`, and executes it. On a thrown transport error or SSH exit code `255`, `.readOnly` invalidates/checks/rebuilds and retries exactly once. `.never` returns the first failure unchanged. Do not retry nonzero remote command exit codes other than `255`.

`shutdown` atomically rejects new preparations, cancels queued waiters, waits for active prepare tasks, sends `stop` to each ready alias, and removes only sockets that no longer pass `check`.

- [ ] **Step 4: Run focused tests, concurrency regressions, and the full suite**

Run: `swift run MerlinLizdCoreTests --filter 'SSH master pool'`

Expected: all pool tests pass.

Run: `swift run MerlinLizdCoreTests --filter 'concurrency regressions'`

Expected: all existing cancellation/process-reaping tests pass.

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

- [ ] **Step 5: Commit the lifecycle module**

```bash
git add Sources/MerlinLizdCore/SSHMasterPool.swift Tests/MerlinLizdCoreTests/SSHMasterPoolTests.swift Tests/MerlinLizdCoreTests/ConcurrencyTestSupport.swift
git diff --cached --check
git commit -m "feat: manage reusable SSH connections"
```

### Task 3: Route every App-owned SSH channel through the pool

**Files:**
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift`
- Modify: `Sources/MerlinLizdCore/TmuxSessionController.swift`
- Modify: `Sources/MerlinLizdCore/MerlinInventory.swift`
- Modify: `Sources/MerlinLizdCore/WorkerMetricsStreamer.swift`
- Modify: `Sources/MerlinLizdApp/TerminalTabsModel.swift`
- Modify: `Sources/MerlinLizdApp/WorkerMonitoringModel.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionControllerTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/MerlinInventoryTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/WorkerMetricsStreamerTests.swift`

**Interfaces:**
- Consumes: `SSHMasterPool.prepare`, `.run`, and `.managedCommand`.
- Produces dependency-injected initializers:

```swift
public init(sshMasterPool: SSHMasterPool, maxConcurrentProcesses: Int = 2) // discovery
public init(sshMasterPool: SSHMasterPool, maxConcurrentProcesses: Int = 4) // controller
public init(sshMasterPool: SSHMasterPool, maxConcurrentProcesses: Int = 4) throws // inventory
public init(sshMasterPool: SSHMasterPool) // metrics streamer
```

- [ ] **Step 1: Make existing tests assert shared `ControlPath` use**

Inject a test pool with a deterministic directory. For Devbox and Worker operations assert that tmux discovery, tmux mutation, Worker fallback/readiness, metrics streaming, and interactive terminal commands all contain the same `ControlPath=/tmp/.../m-<hash>` option. Add a mutation assertion that the pool records `SSHReplayPolicy.never`. Keep `ssh -G alias` assertions unchanged and assert it receives no ControlMaster option.

- [ ] **Step 2: Run the affected tests and verify they fail on direct SSH commands**

Run: `swift run MerlinLizdCoreTests --filter 'tmux|Worker metrics|Merlin inventory'`

Expected: failures showing missing `ControlPath=` or missing injected initializers.

- [ ] **Step 3: Inject the pool into Core clients**

For each remote `TerminalTarget`, obtain the alias through one new helper in `MerlinCommands`:

```swift
public static func sshAlias(for target: TerminalTarget) -> String? {
    switch target {
    case .local: nil
    case let .devbox(_, _, alias), let .worker(_, _, alias, _): alias
    }
}
```

Use `pool.run(... replay: .readOnly)` for discovery and read-only inventory fallbacks. Use `.never` for rename/terminate. Leave local tmux and local Merlin CLI commands on their existing process runners. In `WorkerMetricsStreamer`, await `prepare(alias:priority:.foreground)`, decorate the stream command, and then start the existing `POSIXInventoryProcessStreamer`. Do not add stream replay.

- [ ] **Step 4: Route SwiftTerm and external Terminal commands**

Change `TerminalTabsModel` to receive `SSHMasterPool`, `TmuxSessionDiscovery`, and `TmuxSessionController`. Before constructing a remote `TerminalSession`, call `managedCommand` on the existing `MerlinCommands.devboxTerminal` or `.workerTerminal` result. Apply the same decoration in `openInTerminal`. The child remains `/usr/bin/ssh`, owns its real PTY, and retains the existing `tmux new-session -A` behavior.

Change `WorkerMonitoringModel.init(streamer:)` to store the shared streamer rather than constructing another one.

- [ ] **Step 5: Run all tests and build the App**

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

Run: `swift build --product MerlinLizd`

Expected: `Build complete!` with no Swift concurrency warnings introduced by the new pool.

- [ ] **Step 6: Commit the connection routing**

```bash
git add Sources/MerlinLizdCore/TmuxSessionDiscovery.swift Sources/MerlinLizdCore/TmuxSessionController.swift Sources/MerlinLizdCore/MerlinInventory.swift Sources/MerlinLizdCore/WorkerMetricsStreamer.swift Sources/MerlinLizdApp/TerminalTabsModel.swift Sources/MerlinLizdApp/WorkerMonitoringModel.swift Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift Tests/MerlinLizdCoreTests/TmuxSessionControllerTests.swift Tests/MerlinLizdCoreTests/MerlinInventoryTests.swift Tests/MerlinLizdCoreTests/WorkerMetricsStreamerTests.swift
git diff --cached --check
git commit -m "refactor: share SSH transport across remote features"
```

### Task 4: Timestamped stale-while-revalidate tmux snapshots

**Files:**
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift`

**Interfaces:**
- Consumes: routed read-only execution from Task 3.
- Produces:

```swift
public enum TmuxVerificationState: Equatable, Sendable { case idle, verifying }
public enum TmuxReadinessEvidence: Equatable, Sendable { case ready, workerNotReady, unknown }
// Extend TmuxSessionDiscoveryError with `case transport` so arbitrary runner
// failures become bounded, display-safe snapshot evidence.
public struct TmuxSessionSnapshot: Equatable, Sendable {
    public let target: TerminalTarget
    public let sessions: [TmuxSessionRecord]
    public let readiness: TmuxReadinessEvidence
    public let fetchedAt: Date
    public let verification: TmuxVerificationState
    public let lastError: TmuxSessionDiscoveryError?
    public func isFresh(at now: Date, maximumAge: TimeInterval = 60) -> Bool
}

public func snapshot(target: TerminalTarget) -> TmuxSessionSnapshot?
public func refresh(target: TerminalTarget) async -> TmuxSessionSnapshot
```

- [ ] **Step 1: Add failing cache-semantics tests**

Use an injected `now` closure and scripted runner to prove:

- a snapshot at age 59 seconds is fresh and causes no second process;
- age 61 seconds is returned immediately as stale while one refresh is single-flight;
- a failed refresh retains old sessions/fetchedAt and records `lastError`;
- no-server/no-sessions writes `.ready` plus `[]`;
- Worker-not-ready writes `.workerNotReady` without replacing previous authoritative sessions;
- authoritative rename/termination changes sessions but preserves `fetchedAt`.

The primary fresh-cache assertion should be:

```swift
let first = await discovery.refresh(target: target)
clock.advance(by: 59)
let cached = await discovery.snapshot(target: target)
#expect(cached?.sessions == first.sessions)
#expect(cached?.isFresh(at: clock.now) == true)
#expect(await runner.runCount == 1)
```

- [ ] **Step 2: Run tests and verify the old `[TerminalTarget: CacheEntry]` model fails them**

Run: `swift run MerlinLizdCoreTests --filter 'tmux session inventory'`

Expected: compile failures for `TmuxSessionSnapshot`, followed by behavior failures until the cache is replaced.

- [ ] **Step 3: Replace cache entries with public snapshots and single-flight refreshes**

Store `snapshots: [TerminalTarget: TmuxSessionSnapshot]` and `refreshes: [TerminalTarget: Task<TmuxSessionSnapshot, Never>]`. `refresh` installs `.verifying` on the last-known snapshot, shares one task per target, maps all outcomes into a snapshot, and clears only the matching generation. Never throw away an older authoritative session list on transport failure or Worker-not-ready evidence.

Keep `list(target:) async throws -> [TmuxSessionRecord]` temporarily as a compatibility wrapper around `refresh`; remove callers in Task 6, then delete the wrapper if no production reference remains.

- [ ] **Step 4: Run focused and full tests**

Run: `swift run MerlinLizdCoreTests --filter 'tmux session inventory'`

Expected: all snapshot tests pass.

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

- [ ] **Step 5: Commit the snapshot model**

```bash
git add Sources/MerlinLizdCore/TmuxSessionDiscovery.swift Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift
git diff --cached --check
git commit -m "feat: retain timestamped tmux snapshots"
```

### Task 5: Combined Worker readiness/tmux warmup scheduler

**Files:**
- Modify: `Sources/MerlinLizdCore/MerlinCommands.swift`
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift`
- Create: `Sources/MerlinLizdCore/TargetWarmupCoordinator.swift`
- Modify: `Tests/MerlinLizdCoreTests/CommandBuilderTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift`
- Create: `Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift`

**Interfaces:**
- Consumes: `SSHMasterPool`, `TmuxSessionDiscovery.refresh`, `TerminalTarget`, `TmuxSessionSnapshot`.
- Produces:

```swift
public enum WarmupReason: Sendable { case appLaunch, inventoryChange, manualRefresh, cacheExpiry, foregroundSelection }
public struct TargetWarmupInventory: Equatable, Sendable {
    public let runningDevboxAliases: [String]
    public let workerTargets: [TerminalTarget]
}
public struct TargetWarmupUpdate: Equatable, Sendable {
    public let target: TerminalTarget
    public let snapshot: TmuxSessionSnapshot
}
public actor TargetWarmupCoordinator {
    public init(sshMasterPool: SSHMasterPool, discovery: TmuxSessionDiscovery, maxConcurrentWorkerWarmups: Int = 2)
    public func reconcile(_ inventory: TargetWarmupInventory, reason: WarmupReason, onUpdate: @escaping @Sendable (TargetWarmupUpdate) -> Void)
    public func prioritize(_ target: TerminalTarget)
    public func shutdown() async
}
```

- [ ] **Step 1: Add a failing combined-command test**

For a Worker target, assert exactly one `mlx worker login` remote command contains a fixed readiness marker followed by tmux discovery:

```swift
let command = try MerlinCommands.warmWorker(target: workerTarget)
let remote = try #require(command.arguments.last)
#expect(remote.contains("mlx worker login 3966762 --"))
#expect(remote.contains("printf '__MLZ_READY__\\n'"))
#expect(remote.contains("tmux list-sessions -F#{session_name}"))
#expect(remote.components(separatedBy: "mlx worker login").count == 2)
#expect(!remote.contains("new-session"))
#expect(!remote.contains("attach"))
#expect(!remote.contains("kill"))
```

Use `sh -lc` only with the completely fixed command body after alias and Worker ID validation. Map the marker plus tmux no-server exit to `.ready` with an empty list.

Change the Worker branch of `TmuxSessionDiscovery.refresh` to build `MerlinCommands.warmWorker(target:)`; Devbox and local branches continue using `listTmuxSessions`. Parse the fixed readiness marker before tmux output. This is the point where the former readiness-only `mlx worker login ... -- true` and tmux-only login become one Worker login.

- [ ] **Step 2: Add failing scheduler tests**

Test all of these with controllable discovery gates:

- cached aliases are prepared before the simulated fresh inventory callback;
- selected target, then open/recent targets, run before background targets;
- no more than two Worker refreshes overlap;
- repeated reconciliation is single-flight per target/generation;
- replacing a Worker ID cancels obsolete queued work;
- five-minute refresh re-enqueues current targets through an injected clock/sleeper;
- `shutdown` cancels queued/active warmups and never submits a mutating tmux command.

- [ ] **Step 3: Run tests and verify the coordinator is absent**

Run: `swift run MerlinLizdCoreTests --filter 'warmup|Worker tmux warmup'`

Expected: build failure for the new command/coordinator symbols.

- [ ] **Step 4: Implement priority reconciliation and periodic refresh**

The coordinator stores the latest inventory generation, a bounded two-slot Worker queue, `inFlightTargets`, and an MRU list capped at 32 targets. `prioritize` moves a target to the front and, if queued, reorders it without duplicating work. `reconcile` prepares every running alias in the background, sorts workers by selected/MRU rank, and submits `discovery.refresh` tasks. Each result calls `onUpdate` immediately.

Start one internal periodic task on the first reconciliation. It sleeps for 300 seconds and reconciles the most recent inventory with `.cacheExpiry`. The injected test sleeper must allow deterministic advancement; production uses `Task.sleep(for:)`.

- [ ] **Step 5: Run focused and full tests**

Run: `swift run MerlinLizdCoreTests --filter 'warmup|Worker tmux warmup'`

Expected: all warmup tests pass and observed maximum Worker concurrency is exactly two when at least two targets exist.

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

- [ ] **Step 6: Commit the scheduler**

```bash
git add Sources/MerlinLizdCore/MerlinCommands.swift Sources/MerlinLizdCore/TmuxSessionDiscovery.swift Sources/MerlinLizdCore/TargetWarmupCoordinator.swift Tests/MerlinLizdCoreTests/CommandBuilderTests.swift Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift
git diff --cached --check
git commit -m "feat: prewarm Worker tmux snapshots"
```

### Task 6: Start prewarming at App launch and render cached sessions immediately

**Files:**
- Create: `Sources/MerlinLizdApp/MerlinRemoteRuntime.swift`
- Modify: `Sources/MerlinLizdApp/AppModel.swift`
- Modify: `Sources/MerlinLizdApp/TerminalTabsModel.swift`
- Modify: `Sources/MerlinLizdApp/WorkerMonitoringModel.swift`
- Modify: `Sources/MerlinLizdApp/MachineViews.swift`
- Modify: `Sources/MerlinLizdApp/MerlinRootView.swift`
- Modify: `Sources/MerlinLizdApp/TmuxSessionBrowserView.swift`
- Modify: `Sources/MerlinLizdApp/MerlinLizdApplication.swift`

**Interfaces:**
- Consumes: pool, discovery, controller, streamer, coordinator, safe cached `InventorySnapshot`.
- Produces one `@MainActor final class MerlinRemoteRuntime` with shared service instances and `shutdown()`.

- [ ] **Step 1: Add the App composition root**

Implement:

```swift
@MainActor
final class MerlinRemoteRuntime {
    let sshMasterPool: SSHMasterPool
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    let metricsStreamer: WorkerMetricsStreamer
    let warmupCoordinator: TargetWarmupCoordinator

    init() {
        let pool = SSHMasterPool(maxConcurrentPreparations: 4)
        sshMasterPool = pool
        tmuxDiscovery = TmuxSessionDiscovery(sshMasterPool: pool, maxConcurrentProcesses: 2)
        tmuxController = TmuxSessionController(sshMasterPool: pool)
        metricsStreamer = WorkerMetricsStreamer(sshMasterPool: pool)
        warmupCoordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: tmuxDiscovery,
            maxConcurrentWorkerWarmups: 2
        )
    }

    func shutdown() async {
        await warmupCoordinator.shutdown()
        await WorkerMetricsStreamer.shutdownAll()
        await sshMasterPool.shutdown()
    }
}
```

Construct one runtime in `MerlinLizdApplication.init` and inject it into `AppModel` and `TerminalTabsModel`. Pass `runtime.metricsStreamer` down to `WorkerMonitoringContainer`; do not create another streamer in a view model.

- [ ] **Step 2: Schedule cached-inventory warmup before the first platform refresh**

After `AppModel.init(runtime:)` restores `safe-inventory-snapshot-v1`, immediately start an unstructured MainActor-owned task that converts only running Devboxes with validated aliases and their cached Workers into `TargetWarmupInventory`. Call `reconcile(... reason:.appLaunch)` without awaiting it from the initializer. Repeat reconciliation after each authoritative Worker inventory merge.

Replace the separate `probeWorker` scheduling path with `TargetWarmupUpdate.snapshot.readiness`. Apply updates only when the target still matches the current Devbox SID, alias, and Worker ID. Map `.ready` to `WorkerReadiness.ready`, `.workerNotReady` to `.notReady`, and `.unknown`/transport failure to `.unreachable` while retaining the session snapshot in discovery.

Delete the now-redundant AppModel readiness scheduler state (`workerProbeTask`, `workerProbeGeneration`, `readinessRescanPending`, `pendingReadinessForce`, and `readinessCache`) plus its scheduling/finish helpers. Keep readiness timestamps only in the persisted safe inventory projection if existing decode compatibility requires them; do not launch `MerlinInventory.probeWorker` from the App after this task. This removal is required to prevent a second Worker login from racing the combined warmup.

Call `warmupCoordinator.prioritize` when sidebar selection changes, a terminal opens/selects, or a session browser target is chosen. Reversed open-tab order is the MRU seed; selected tab is first.

- [ ] **Step 3: Change the browser model to stale-while-revalidate**

`TmuxSessionBrowserModel.load(force:)` must:

1. read `discovery.snapshot(target:)` and merge it with restored/open tab sessions;
2. publish `fetchedAt`, `isStale`, `isVerifying`, and target-scoped error immediately;
3. return without a remote request when age is at most 60 seconds and `force == false`;
4. otherwise start one background `refresh`, leaving the current list visible;
5. replace sessions only with a newer authoritative ready response.

The Refresh button calls `load(force: true)`. Replace the blocking copy `正在核对远端；mlx 冷启动最长约 45 秒` with a compact status beside the timestamp: `刚刚更新`, `后台核对中`, or `缓存 · <time>`. A verification failure with cached sessions appears as a nonmodal warning banner; the empty-state error remains only when no snapshot or known tab session exists.

- [ ] **Step 4: Build and manually verify startup behavior**

Run: `swift build --product MerlinLizd`

Expected: `Build complete!`.

Launch the App from Xcode or the existing packaging command, then verify:

- the machine tree paints before any Worker warmup finishes;
- Activity Monitor shows no more than two concurrent `mlx worker login` warmups;
- opening a warmed Worker's session sheet displays cached sessions immediately;
- opening the same sheet again within 60 seconds creates no new Worker login;
- after 60 seconds the old list remains visible while `后台核对中` appears;
- a Worker-not-ready result does not replace a previously known session list with an empty list;
- opening a terminal still attaches/creates its requested tmux session.

- [ ] **Step 5: Run the full Core suite and commit App integration**

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

```bash
git add Sources/MerlinLizdApp/MerlinRemoteRuntime.swift Sources/MerlinLizdApp/AppModel.swift Sources/MerlinLizdApp/TerminalTabsModel.swift Sources/MerlinLizdApp/WorkerMonitoringModel.swift Sources/MerlinLizdApp/MachineViews.swift Sources/MerlinLizdApp/MerlinRootView.swift Sources/MerlinLizdApp/TmuxSessionBrowserView.swift Sources/MerlinLizdApp/MerlinLizdApplication.swift
git diff --cached --check
git commit -m "feat: prewarm remote sessions at launch"
```

### Task 7: Graceful shutdown, regression guardrails, and measured handoff

**Files:**
- Modify: `Sources/MerlinLizdApp/MerlinLizdApplication.swift`
- Modify: `Tests/MerlinLizdCoreTests/SSHMasterPoolTests.swift`
- Modify: `Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift`
- Modify: `README.md`
- Modify: `Docs/SPEC.md`

**Interfaces:**
- Consumes: `MerlinRemoteRuntime.shutdown()`.
- Produces an App delegate with one idempotent termination task and documented performance boundaries.

- [ ] **Step 1: Add shutdown race tests**

Add tests that hold an active read-only warmup, call coordinator/pool shutdown, then assert:

- queued work is cancelled before another child starts;
- the active local child is cancelled and reaped;
- later `prepare` returns `.failed` without launching a process;
- each established alias receives at most one `ssh -O stop`;
- recorded argv contains no `tmux kill`, `kill-session`, `rename-session`, `worker stop`, or `worker delete`.

- [ ] **Step 2: Run the shutdown tests and fix any race**

Run: `swift run MerlinLizdCoreTests --filter 'shutdown|SSH master pool|warmup'`

Expected: all shutdown tests pass repeatedly. Run the command three times to catch scheduling races.

- [ ] **Step 3: Wire idempotent App termination**

Give `MerlinLizdApplicationDelegate` a reference to the one runtime created by the App. `applicationShouldTerminate` returns `.terminateLater`, starts exactly one task, awaits `runtime.shutdown()`, then calls `reply(toApplicationShouldTerminate: true)`. A second callback while termination is in progress must return `.terminateLater` without starting another task.

- [ ] **Step 4: Measure the agreed success criteria**

With `hl_gpu_2` and Worker `3966762`, record three baseline runs before App startup. After startup, repeat with the App-owned control path explicitly supplied so the shell measurement uses the same master:

```bash
/usr/bin/time -p ssh hl_gpu_2 true
/usr/bin/time -p ssh hl_gpu_2 'tmux list-sessions -F#{session_name}'
/usr/bin/time -p ssh hl_gpu_2 'NO_COLOR=1 TERM=dumb mlx worker login 3966762 -- tmux list-sessions -F#{session_name}'

ALIAS_HASH="$(printf %s hl_gpu_2 | shasum -a 256 | cut -c1-24)"
CONTROL_PATH="${TMPDIR%/}/mlz-ssh-$(id -u)/m-${ALIAS_HASH}"
/usr/bin/time -p ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ControlPersist=600 hl_gpu_2 true
/usr/bin/time -p ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ControlPersist=600 hl_gpu_2 'tmux list-sessions -F#{session_name}'
/usr/bin/time -p ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ControlPersist=600 hl_gpu_2 'NO_COLOR=1 TERM=dumb mlx worker login 3966762 -- tmux list-sessions -F#{session_name}'
```

Also record App-observed time from sheet presentation to cached rows. Confirm the expected boundary: warmed Devbox operations avoid the measured handshake, warmed Worker sheets render from cache immediately, but the first Worker terminal may still pay `mlx worker login` latency.

- [ ] **Step 5: Document behavior and deferred Worker agent phase**

Update `README.md` and `Docs/SPEC.md` with:

- App-owned sockets and unchanged user SSH configuration;
- launch prewarming and Worker concurrency two;
- 60-second freshness and five-minute refresh;
- stale snapshots remaining visible on verification failure;
- default tab/App close preserving tmux;
- the explicit terminate-session action as the only tmux-killing path;
- the deferred long-lived Worker `agent --stdio` option if terminal-first-byte latency remains unacceptable.

- [ ] **Step 6: Final verification and commit**

Run: `swift run MerlinLizdCoreTests`

Expected: all tests pass.

Run: `swift build --product MerlinLizd`

Expected: `Build complete!`.

Run: `git diff --check`

Expected: no whitespace errors.

```bash
git add Sources/MerlinLizdApp/MerlinLizdApplication.swift Tests/MerlinLizdCoreTests/SSHMasterPoolTests.swift Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift README.md Docs/SPEC.md
git diff --cached --check
git commit -m "docs: verify SSH prewarming behavior"
```

## Final Acceptance Checklist

- [ ] The first App frame is not gated on SSH or Worker login.
- [ ] Every running Devbox has at most one App-owned master socket.
- [ ] All App-owned tmux reads/mutations, Worker fallback/readiness, metrics, SwiftTerm, and external Terminal SSH commands use that socket.
- [ ] Fresh sheets issue no remote request; stale sheets remain usable while verification runs.
- [ ] Worker warmup covers all current Workers with at most two logins at once.
- [ ] No prewarm or shutdown command mutates tmux or Worker lifecycle.
- [ ] Mutations are not replayed after ambiguous transport loss.
- [ ] App shutdown leaves remote tmux sessions and their tasks intact.
- [ ] The user's SSH configuration is byte-for-byte unchanged.
- [ ] Core tests and the App build pass from the final tree.
