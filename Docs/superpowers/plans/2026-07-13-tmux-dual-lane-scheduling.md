# Tmux Dual-Lane Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let foreground tmux browsing execute independently of up to 16 concurrent background Worker warmups while preserving per-target single-flight behavior.

**Architecture:** Add an explicit refresh lane to `TmuxSessionDiscovery` and give foreground and background remote work separate timeout/concurrency runners. `TargetWarmupCoordinator` uses the background lane with a default capacity of 16; the session browser uses the foreground lane. Both lanes retain one shared snapshot cache and one shared per-target task map.

**Tech Stack:** Swift 6, Swift Concurrency actors/tasks, Swift Testing, SwiftPM.

## Global Constraints

- Background remote Worker discovery is limited to exactly 16 concurrent operations.
- Foreground discovery uses an independent execution runner and consumes no background slot.
- Requests for the same `TerminalTarget` share one in-flight task across lanes.
- Remote command timeouts remain 45 seconds in production.
- Local and Devbox discovery, SSH master reuse, cache freshness, cancellation, and shutdown semantics remain unchanged.

---

### Task 1: Separate Foreground and Background Discovery Lanes

**Files:**
- Modify: `Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift:489-569`
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift:12-138,187-228,310-365`
- Modify: `Sources/MerlinLizdCore/TargetWarmupCoordinator.swift:231-250`
- Modify: `Sources/MerlinLizdApp/TmuxSessionBrowserView.swift:43-57`

**Interfaces:**
- Produces: `public enum TmuxRefreshLane: Sendable { case foreground, background }`
- Produces: `refresh(target:lane:)` and `refreshIfStale(target:maximumAge:lane:)`, both defaulting to `.foreground`.
- Consumes: `TargetWarmupCoordinator` passes `.background`; `TmuxSessionBrowserModel` passes `.foreground`.

- [ ] **Step 1: Replace the shared-slot test with a failing lane-isolation test**

Update the existing pooled discovery test so two gated background refreshes are active, then start a third target in the foreground and require all three remote children to be active:

```swift
@Test("foreground discovery bypasses occupied background slots")
func foregroundDiscoveryBypassesBackgroundSlots() async {
    let runner = GatedPooledDiscoveryRunner()
    let pool = SSHMasterPool(
        testDirectory: temporarySSHDirectory(),
        runner: runner
    )
    #expect(await pool.prepare(alias: "hl_gpu_2", priority: .foreground) == .ready)
    let discovery = TmuxSessionDiscovery(
        sshMasterPool: pool,
        processRunner: TmuxScriptedRunner(output: .init(
            stdout: "must-not-run", stderr: "", exitCode: 0
        )),
        foregroundExecutionPolicy: BoundedAsyncOperationRunner(
            maxConcurrentOperations: 2,
            timeout: .seconds(5)
        ),
        backgroundExecutionPolicy: BoundedAsyncOperationRunner(
            maxConcurrentOperations: 2,
            timeout: .seconds(5)
        )
    )
    let coordinator = TargetWarmupCoordinator(
        sshMasterPool: pool,
        discovery: discovery,
        maxConcurrentWorkerWarmups: 2
    )
    await coordinator.reconcile(
        .init(
            runningDevboxAliases: [],
            workerTargets: [
                pooledWorker("7000001"), pooledWorker("7000002"),
            ]
        ),
        reason: .inventoryChange,
        onUpdate: { _ in }
    )
    await runner.waitForChildStarts(2)

    let browser = Task {
        await discovery.refresh(
            target: pooledWorker("7000003"),
            lane: .foreground
        )
    }
    await runner.waitForChildStarts(3)
    #expect(await runner.childStartCount() == 3)
    #expect(await runner.maximumChildConcurrency() == 3)
    await runner.releaseAll()
    _ = await browser.value
    await coordinator.shutdown()
    await pool.shutdown()
}
```

Also add this cross-lane single-flight test:

```swift
@Test("foreground joins an in-flight background refresh for the same Worker")
func foregroundJoinsBackgroundRefreshForSameWorker() async {
    let runner = GatedPooledDiscoveryRunner()
    let pool = SSHMasterPool(
        testDirectory: temporarySSHDirectory(),
        runner: runner
    )
    #expect(await pool.prepare(alias: "hl_gpu_2", priority: .foreground) == .ready)
    let discovery = TmuxSessionDiscovery(
        sshMasterPool: pool,
        processRunner: TmuxScriptedRunner(output: .init(
            stdout: "must-not-run", stderr: "", exitCode: 0
        )),
        foregroundExecutionPolicy: BoundedAsyncOperationRunner(
            maxConcurrentOperations: 2,
            timeout: .seconds(5)
        ),
        backgroundExecutionPolicy: BoundedAsyncOperationRunner(
            maxConcurrentOperations: 2,
            timeout: .seconds(5)
        )
    )
    let target = pooledWorker("7000004")
    let background = Task {
        await discovery.refresh(target: target, lane: .background)
    }
    await runner.waitForChildStarts(1)
    let foreground = Task {
        await discovery.refresh(target: target, lane: .foreground)
    }
    for _ in 0 ..< 1_000 { await Task.yield() }
    #expect(await runner.childStartCount() == 1)

    await runner.releaseAll()
    _ = await (background.value, foreground.value)
    await pool.shutdown()
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run: `./scripts/test.sh`

Expected: compilation fails because `TmuxRefreshLane`, the `lane:` argument, and the separate execution-policy initializer arguments do not exist yet.

- [ ] **Step 3: Implement lane-aware discovery**

Add the lane and separate policies:

```swift
public enum TmuxRefreshLane: Sendable {
    case foreground
    case background
}

private let foregroundExecutionPolicy: BoundedAsyncOperationRunner?
private let backgroundExecutionPolicy: BoundedAsyncOperationRunner?
```

The production initializer creates two independent runners with 45-second timeouts. The background runner uses the existing `maxConcurrentProcesses` parameter until Task 2 raises and renames it; the foreground runner is independently bounded to 16. Thread the lane through `refresh`, `refreshIfStale`, `startRefresh`, and `loadSnapshot`. Keep `refreshes` keyed only by `TerminalTarget`, so a second lane joins the existing task.

At the SSH execution boundary, select the independent runner without changing command construction or replay behavior:

```swift
let executionPolicy = switch lane {
case .foreground: foregroundExecutionPolicy
case .background: backgroundExecutionPolicy
}
if let executionPolicy {
    output = try await executionPolicy.run {
        try await sshMasterPool.run(command, alias: alias, replay: .readOnly)
    }
} else {
    output = try await sshMasterPool.run(command, alias: alias, replay: .readOnly)
}
```

Make implicit stale-cache refreshes use `.background`, make the warmup coordinator call `refresh(target:lane: .background)`, and make both browser refresh branches explicitly pass `.foreground`. Update the pooled-timeout test to inject its 300 ms runner as `foregroundExecutionPolicy`.

- [ ] **Step 4: Run the suite and verify GREEN**

Run: `./scripts/test.sh`

Expected: all tmux discovery, timeout, cache, mutation, shutdown, and existing repository tests pass; the lane-isolation test observes three simultaneous children and the cross-lane test observes one child.

- [ ] **Step 5: Commit the lane separation**

```bash
git add Sources/MerlinLizdCore/TmuxSessionDiscovery.swift \
  Sources/MerlinLizdCore/TargetWarmupCoordinator.swift \
  Sources/MerlinLizdApp/TmuxSessionBrowserView.swift \
  Tests/MerlinLizdCoreTests/TmuxSessionDiscoveryTests.swift
git commit -m "fix: isolate foreground tmux discovery"
```

### Task 2: Raise Background Worker Concurrency to 16

**Files:**
- Modify: `Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift:77-101,366-390`
- Modify: `Sources/MerlinLizdCore/TmuxSessionDiscovery.swift:65-87`
- Modify: `Sources/MerlinLizdCore/TargetWarmupCoordinator.swift:62-87`
- Modify: `Sources/MerlinLizdApp/MerlinRemoteRuntime.swift:13-26`

**Interfaces:**
- Consumes: `.background` refresh lane from Task 1.
- Produces: `TargetWarmupCoordinator` default `maxConcurrentWorkerWarmups: Int = 16`.
- Produces: production runtime configured with `maxConcurrentBackgroundWorkerRefreshes: 16` and `maxConcurrentWorkerWarmups: 16`.

- [ ] **Step 1: Write the failing 16-way concurrency test**

Replace the default two-way test with 17 distinct gated Workers. Assert that 16 start before a gate is released, the seventeenth starts only after one release, and maximum background concurrency remains 16:

```swift
@Test("warmup runs no more than sixteen Worker refreshes concurrently")
func boundsWorkerConcurrency() async {
    let runner = WarmupDiscoveryRunner(gated: true)
    let coordinator = makeWarmupCoordinator(runner: runner)
    let workers = (1 ... 17).map {
        warmupWorker(String(2_000_000 + $0))
    }
    await coordinator.reconcile(
        .init(runningDevboxAliases: [], workerTargets: workers),
        reason: .inventoryChange,
        onUpdate: { _ in }
    )
    await runner.waitForStarts(2)
    for _ in 0 ..< 10_000 {
        if await runner.startedWorkerIDs().count >= 16 { break }
        await Task.yield()
    }
    let initialCount = await runner.startedWorkerIDs().count
    #expect(initialCount == 16)
    guard initialCount == 16 else {
        await runner.releaseAll()
        await coordinator.shutdown()
        return
    }
    #expect(await runner.maximumConcurrency() == 16)
    await runner.releaseNext()
    await runner.waitForStarts(17)
    #expect(await runner.maximumConcurrency() == 16)
    await runner.releaseAll()
    await coordinator.shutdown()
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run: `./scripts/test.sh`

Expected: FAIL because only two refreshes start under the old default, so `initialCount` is 2 instead of 16. The guard releases the gates and shuts down cleanly after recording the failure.

- [ ] **Step 3: Set production and coordinator limits to 16**

Change both `TargetWarmupCoordinator` initializers' default to 16. Rename the discovery production initializer parameter to `maxConcurrentBackgroundWorkerRefreshes` and configure the runtime explicitly:

```swift
tmuxDiscovery = TmuxSessionDiscovery(
    sshMasterPool: pool,
    maxConcurrentBackgroundWorkerRefreshes: 16
)
warmupCoordinator = TargetWarmupCoordinator(
    sshMasterPool: pool,
    discovery: tmuxDiscovery,
    maxConcurrentWorkerWarmups: 16
)
```

- [ ] **Step 4: Run full verification**

Run: `./scripts/test.sh && /usr/bin/swift build`

Expected: the complete test executable reports zero failures and the app plus Core targets build successfully.

- [ ] **Step 5: Review the diff and commit**

Run: `git diff --check && git diff --stat && git status --short`

Verify that `AGENTS.md` remains untracked and unstaged. Then commit only the concurrency changes:

```bash
git add Sources/MerlinLizdCore/TargetWarmupCoordinator.swift \
  Sources/MerlinLizdCore/TmuxSessionDiscovery.swift \
  Sources/MerlinLizdApp/MerlinRemoteRuntime.swift \
  Tests/MerlinLizdCoreTests/TargetWarmupCoordinatorTests.swift
git commit -m "perf: allow sixteen Worker tmux warmups"
```
