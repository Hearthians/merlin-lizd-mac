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
