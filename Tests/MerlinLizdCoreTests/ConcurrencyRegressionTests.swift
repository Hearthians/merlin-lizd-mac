import Darwin
import Testing
@testable import MerlinLizdCore

@Suite("Concurrency regressions")
struct ConcurrencyRegressionTests {
    @Test("a timed runner cancels a command that exceeds its budget")
    func commandTimeoutCancelsUnderlyingWork() async {
        let underlying = RecordingDelayedProcessRunner()
        let runner = TimedInventoryProcessRunner(
            timeout: .milliseconds(5),
            underlying: underlying
        )

        await #expect(throws: InventoryProcessTimeoutError.timedOut) {
            _ = try await runner.run(command(label: "slow"))
        }
    }

    @Test("fast child exits never strand process waiters")
    func fastChildExitsComplete() async throws {
        let runner = FoundationInventoryProcessRunner()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let output = try await runner.run(CommandSpec(
                        executable: "/usr/bin/true",
                        arguments: []
                    ))
                    guard output.exitCode == 0 else {
                        throw ConcurrencyRegressionTestError.unexpectedExit
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("authoritative process completion wins a later task cancellation")
    func authoritativeCompletionWinsLateCancellation() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()
        let descendantProbeFile = TemporaryProcessIDFile()
        let descendantProbeFIFO = TemporaryMarkerFile()
        let completionGate = AsyncStartGate()
        let (cancellationDecisions, cancellationDecisionContinuation) =
            AsyncStream<Bool>.makeStream()
        var cancellationDecisionIterator = cancellationDecisions.makeAsyncIterator()
        let runner = FoundationInventoryProcessRunner(
            cancellationDecisionHook: { cancelled in
                cancellationDecisionContinuation.yield(cancelled)
            },
            completionBoundaryHook: {
                await completionGate.wait()
            }
        )
        let task = Task {
            try await runner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; /bin/sh -c '/usr/bin/mkfifo \"$2\"; exec 3<> \"$2\"; trap \"echo \\$\\$ > \\\"$1\\\"\" USR1; exec 1>&- 2>&-; while :; do read value <&3; done' probe \"$3\" \"$4\" & echo $! > \"$2\"; exit 0",
                    "merlin-lizd-finalized-cancel-test",
                    parentPIDFile.path,
                    descendantPIDFile.path,
                    descendantProbeFile.path,
                    descendantProbeFIFO.path,
                ]
            ))
        }
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?

        try await withAsyncCleanup({
            await completionGate.waitUntilEntered()
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            #expect(parentPIDFile.processIsAbsent(try #require(parentProcessID)))
            #expect(!descendantPIDFile.processIsAbsent(
                try #require(descendantProcessID)
            ))
            task.cancel()
            #expect(await cancellationDecisionIterator.next() == false)
            #expect(kill(try #require(descendantProcessID), SIGUSR1) == 0)
            #expect(
                try await descendantProbeFile.waitForProcessID()
                    == descendantProcessID
            )
            await completionGate.open()

            let output = try await task.value
            #expect(output.exitCode == 0)
        }, cleanup: {
            task.cancel()
            await completionGate.open()
            if let parentProcessID {
                _ = kill(parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            _ = try? await task.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
            descendantProbeFile.remove()
            descendantProbeFIFO.remove()
        })
    }

    @Test("cancellation after leader exit terminates a descendant holding output pipes")
    func cancellationDuringOutputDrainTerminatesDescendant() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()

        let exitGate = AsyncStartGate()
        let runner = FoundationInventoryProcessRunner(
            processExitBoundaryHook: {
                await exitGate.wait()
            }
        )
        let task = Task {
            try await runner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; /bin/sleep 30 & echo $! > \"$2\"; exit 0",
                    "merlin-lizd-drain-cancel-test",
                    parentPIDFile.path,
                    descendantPIDFile.path,
                ]
            ))
        }
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?

        try await withAsyncCleanup({
            await exitGate.waitUntilEntered()
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            let descendant = try #require(descendantProcessID)
            #expect(parentPIDFile.processHasExitedWithoutReaping(parent))
            #expect(!descendantPIDFile.processIsAbsent(descendant))

            task.cancel()
            await exitGate.open()

            let descendantWasTerminated = await descendantPIDFile
                .waitUntilProcessIsAbsent(descendant)
            if !descendantWasTerminated {
                _ = kill(-parent, SIGKILL)
                _ = await descendantPIDFile.waitUntilProcessIsAbsent(
                    descendant
                )
            }
            #expect(descendantWasTerminated)
            await expectCancellation(from: task)
            #expect(await parentPIDFile.waitUntilProcessIsAbsent(parent))
        }, cleanup: {
            task.cancel()
            await exitGate.open()
            if let parentProcessID {
                _ = kill(-parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            _ = try? await task.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
        })
    }

    @Test("cancellation before atomic finalization kills the group before reap")
    func cancellationBeforeFinalizationTerminatesDescendant() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()

        let decisionGate = AsyncStartGate()
        let runner = FoundationInventoryProcessRunner(
            completionDecisionBoundaryHook: {
                await decisionGate.wait()
            }
        )
        let task = Task {
            try await runner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; /bin/sh -c 'trap \"\" TERM; exec 1>&- 2>&-; exec /bin/sleep 30' & echo $! > \"$2\"; exit 0",
                    "merlin-lizd-reap-cancel-test",
                    parentPIDFile.path,
                    descendantPIDFile.path,
                ]
            ))
        }
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?

        try await withAsyncCleanup({
            await decisionGate.waitUntilEntered()
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            let descendant = try #require(descendantProcessID)
            #expect(parentPIDFile.processHasExitedWithoutReaping(parent))
            #expect(getpgid(descendant) == parent)

            let clock = ContinuousClock()
            let cancelledAt = clock.now
            task.cancel()
            task.cancel()
            await decisionGate.open()
            await expectCancellation(from: task)
            #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
            #expect(parentPIDFile.processIsAbsent(parent))
            #expect(await descendantPIDFile.waitUntilProcessIsAbsent(descendant))
        }, cleanup: {
            task.cancel()
            await decisionGate.open()
            if let parentProcessID {
                _ = kill(-parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            _ = try? await task.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
        })
    }

    @Test("a task cancelled before process launch never starts the child")
    func cancellationBeforeLaunchDoesNotStartProcess() async throws {
        let marker = TemporaryMarkerFile()
        defer { marker.remove() }

        let gate = AsyncStartGate()
        let runner = FoundationInventoryProcessRunner()
        let task = Task {
            await gate.wait()
            return try await runner.run(CommandSpec(
                executable: "/usr/bin/touch",
                arguments: [marker.path]
            ))
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        await expectCancellation(from: task)
        #expect(!marker.exists)
    }

    @Test("cancelling a running process terminates and reaps the child")
    func cancellationTerminatesAndReapsProcess() async throws {
        let pidFile = TemporaryProcessIDFile()

        let runner = FoundationInventoryProcessRunner()
        let task = Task {
            try await runner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; exec /bin/sleep 30",
                    "merlin-lizd-process-test",
                    pidFile.path,
                ]
            ))
        }
        var processID: pid_t?

        try await withAsyncCleanup({
            processID = try await pidFile.waitForProcessID()
            let child = try #require(processID)
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            task.cancel()

            await expectCancellation(from: task)
            let cancellationDuration = cancelledAt.duration(to: clock.now)
            #expect(cancellationDuration < .seconds(1))
            #expect(pidFile.processIsAbsent(child))
        }, cleanup: {
            task.cancel()
            if let processID {
                _ = kill(processID, SIGKILL)
            }
            _ = try? await task.value
            pidFile.remove()
        })
    }

    @Test("timeout force-kills a TERM-resistant process group")
    func timeoutForceKillsTermResistantProcessGroup() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?
        let runner = TimedInventoryProcessRunner(
            timeout: .seconds(1),
            underlying: FoundationInventoryProcessRunner()
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let task = Task {
            try await runner.run(CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; /bin/sh -c 'trap \"\" TERM; exec /bin/sleep 30' & echo $! > \"$2\"; wait",
                    "merlin-lizd-term-resistant-test",
                    parentPIDFile.path,
                    descendantPIDFile.path,
                ]
            ))
        }

        try await withAsyncCleanup({
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            #expect(getpgid(parent) == parent)
            #expect(parent != getpgrp())
            if let descendantProcessID {
                #expect(getpgid(descendantProcessID) == parent)
            }

            try await clock.sleep(
                until: startedAt.advanced(by: .milliseconds(1_500))
            )
            #expect(parentPIDFile.processIsAbsent(parent))
            if let descendantProcessID {
                #expect(descendantPIDFile.processIsAbsent(descendantProcessID))
            }

            await #expect(throws: InventoryProcessTimeoutError.timedOut) {
                _ = try await task.value
            }

            let elapsed = startedAt.duration(to: clock.now)
            #expect(elapsed >= .seconds(1))
            #expect(elapsed < .seconds(3))
            #expect(await parentPIDFile.waitUntilProcessIsAbsent(parent))
            if let descendantProcessID {
                #expect(await descendantPIDFile.waitUntilProcessIsAbsent(
                    descendantProcessID
                ))
            }
        }, cleanup: {
            task.cancel()
            if let parentProcessID {
                _ = kill(-parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            _ = try? await task.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
        })
    }

    @Test("a cancelled slot waiter never reaches the underlying runner")
    func cancellationRemovesBoundedRunnerWaiter() async throws {
        let underlying = RecordingDelayedProcessRunner()
        let runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 1,
            underlying: underlying
        )

        let first = Task {
            try await runner.run(command(label: "first"))
        }
        await underlying.waitUntilCommandCount(1)

        let cancelled = Task {
            try await runner.run(command(label: "cancelled"))
        }
        await Task.yield()
        cancelled.cancel()
        let last = Task {
            try await runner.run(command(label: "last"))
        }

        _ = try await first.value
        await expectCancellation(from: cancelled)
        _ = try await last.value

        #expect(await underlying.labels() == ["first", "last"])
    }

    @Test("repeated overlapping callers never overlap refresh commands")
    func overlappingCallersKeepOneRefreshInFlight() async throws {
        let runner = OverlapTrackingEmptyInventoryRunner()
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    for _ in 0..<10 {
                        _ = try? await inventory.refresh(sshAliases: [])
                    }
                }
            }
        }

        #expect(await runner.maximumConcurrentCommands() == 1)
    }

    @Test("many terminal publications waits interrupts and endpoint closes drain exact keys")
    func terminalLifecycleStressDrainsExactKeys() async throws {
        let result = try await CodexTerminalConcurrencyHarness.run(
            publicationCount: 64,
            keysPerOutcome: 8
        )

        #expect(result.completedWaitCount == 8)
        #expect(result.interruptedWaitCount == 16)
        #expect(result.remainingContinuationCount == 0)
        #expect(result.crossKeyMutationCount == 0)
        #expect(result.remainingPinCount == 0)
    }

    private func command(label: String) -> CommandSpec {
        CommandSpec(executable: "/usr/bin/true", arguments: [label])
    }

    private func expectCancellation(
        from task: Task<InventoryProcessOutput, Error>
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}

private struct CodexTerminalConcurrencyResult: Sendable {
    let completedWaitCount: Int
    let interruptedWaitCount: Int
    let remainingContinuationCount: Int
    let crossKeyMutationCount: Int
    let remainingPinCount: Int
}

private actor CodexTerminalConcurrencyPort: TerminalSessionPort {
    private struct Waiter {
        let id: Int
        let afterRevision: UInt64
        let continuation: CheckedContinuation<
            TerminalScreenWaitResult,
            any Error
        >
    }

    private let keyLabel: String
    private var screen: TerminalScreenSnapshot
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 0
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendCount = 0
    private var owners: [TerminalKeyboardOwner] = []

    init(keyLabel: String) {
        self.keyLabel = keyLabel
        screen = TerminalToolFixtures.screen(
            revision: 0,
            text: "\(keyLabel):0"
        )
    }

    func observeScreen() -> TerminalScreenSnapshot { screen }

    func sendInput(_ batch: TerminalInputBatch) -> TerminalInputReceipt {
        sendCount += 1
        return TerminalInputReceipt(
            acceptedRevision: batch.expectedRevision,
            byteCount: batch.events.count
        )
    }

    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        let afterRevision: UInt64
        switch request.condition {
        case let .changed(after): afterRevision = after
        case let .stable(after, _): afterRevision = after
        }
        if screen.revision > afterRevision {
            return TerminalScreenWaitResult(snapshot: screen, timedOut: false)
        }
        nextWaiterID += 1
        let id = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(
                    id: id,
                    afterRevision: afterRevision,
                    continuation: continuation
                )
                let registered = registrationWaiters
                registrationWaiters.removeAll()
                registered.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) {
        owners.append(owner)
    }

    func waitUntilRegistered() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { registrationWaiters.append($0) }
    }

    func publish(revisions: ClosedRange<UInt64>) {
        for revision in revisions {
            screen = TerminalToolFixtures.screen(
                revision: revision,
                text: "\(keyLabel):\(revision)"
            )
            let completed = waiters.values.filter {
                revision > $0.afterRevision
            }
            for waiter in completed {
                waiters.removeValue(forKey: waiter.id)
                waiter.continuation.resume(returning: TerminalScreenWaitResult(
                    snapshot: screen,
                    timedOut: false
                ))
            }
        }
    }

    func continuationCount() -> Int { waiters.count }
    func mutationCount() -> Int { sendCount }

    private func cancelWaiter(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private enum CodexTerminalConcurrencyHarness {
    private struct Context: Sendable {
        let key: TerminalConversationKey
        let endpointID: TerminalEndpointID
        let port: CodexTerminalConcurrencyPort
        let handle: AgentTurnHandle
        let turnID: AgentTurnID
    }

    static func run(
        publicationCount: UInt64,
        keysPerOutcome: Int
    ) async throws -> CodexTerminalConcurrencyResult {
        precondition(publicationCount > 0)
        precondition(keysPerOutcome > 0)
        let registry = TerminalEndpointRegistry()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        var contexts: [Context] = []
        for index in 0..<(keysPerOutcome * 3) {
            let identity = TmuxSessionIdentity(
                serverSessionID: "$stress-\(index)",
                createdAtEpoch: Int64(10_000 + index)
            )
            let key = TerminalConversationKey(target: .local, tmux: identity)
            let endpointID = TerminalEndpointID(
                rawValue: TerminalToolFixtures.newID()
            )
            let port = CodexTerminalConcurrencyPort(
                keyLabel: identity.serverSessionID
            )
            try await registry.register(TerminalEndpoint(
                id: endpointID,
                conversationKey: key,
                terminal: port,
                surfaces: FakeTerminalSurfaceController(surface: TmuxSurface(
                    sessionIdentity: identity,
                    windowID: "@\(index)",
                    paneID: "%\(index)",
                    currentCommand: "zsh"
                )),
                route: TmuxRoute(
                    target: .local,
                    sessionName: "stress-\(index)",
                    expectedIdentity: identity
                )
            ))
            let handle = try await router.beginTurn(
                threadID: .init(rawValue: "stress-thread-\(index)"),
                conversationKey: key
            )
            contexts.append(Context(
                key: key,
                endpointID: endpointID,
                port: port,
                handle: handle,
                turnID: .init(rawValue: "stress-turn-\(index)")
            ))
        }

        let operations = contexts.map { context in
            Task {
                try await router.execute(
                    handle: context.handle,
                    turnID: context.turnID,
                    conversationKey: context.key,
                    call: .waitForScreen(.init(
                        condition: .changed(after: 0),
                        timeout: .seconds(60)
                    ))
                )
            }
        }
        for context in contexts {
            await context.port.waitUntilRegistered()
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<keysPerOutcome {
                let context = contexts[index]
                group.addTask {
                    await context.port.publish(revisions: 1...publicationCount)
                }
            }
            for index in keysPerOutcome..<(keysPerOutcome * 2) {
                let context = contexts[index]
                group.addTask {
                    try? await router.interruptTurn(
                        handle: context.handle,
                        turnID: context.turnID
                    )
                }
            }
            for index in (keysPerOutcome * 2)..<(keysPerOutcome * 3) {
                let context = contexts[index]
                group.addTask {
                    await registry.unregister(context.endpointID)
                    try? await router.interruptTurn(
                        handle: context.handle,
                        turnID: context.turnID
                    )
                }
            }
        }

        var completedWaitCount = 0
        var interruptedWaitCount = 0
        var crossKeyMutationCount = 0
        for (index, operation) in operations.enumerated() {
            do {
                let result = try await operation.value
                guard index < keysPerOutcome,
                    case let .screenWait(wait) = result
                else {
                    crossKeyMutationCount += 1
                    continue
                }
                completedWaitCount += 1
                let expectedLabel = contexts[index].key.tmux.serverSessionID
                if !wait.snapshot.text.hasPrefix("\(expectedLabel):") {
                    crossKeyMutationCount += 1
                }
            } catch TerminalToolRouterError.interrupted {
                if index < keysPerOutcome {
                    crossKeyMutationCount += 1
                } else {
                    interruptedWaitCount += 1
                }
            } catch {
                crossKeyMutationCount += 1
            }
        }

        for index in 0..<keysPerOutcome {
            let context = contexts[index]
            try await router.endTurn(
                handle: context.handle,
                turnID: context.turnID
            )
        }
        var remainingContinuationCount = 0
        for context in contexts {
            remainingContinuationCount += await context.port
                .continuationCount()
            crossKeyMutationCount += await context.port.mutationCount()
        }
        let remainingPinCount = await registry.pinSnapshot().pins.count
        return CodexTerminalConcurrencyResult(
            completedWaitCount: completedWaitCount,
            interruptedWaitCount: interruptedWaitCount,
            remainingContinuationCount: remainingContinuationCount,
            crossKeyMutationCount: crossKeyMutationCount,
            remainingPinCount: remainingPinCount
        )
    }
}
