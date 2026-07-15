import Testing
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

@Suite("Codex app-server supervisor", .serialized)
struct CodexAppServerSupervisorTests {
    @Test("concurrent first demand starts one generation and becomes ready")
    func coalescesLazyStartup() async throws {
        let generation = ScriptedSupervisorGeneration(
            startedThreads: ["thread-1", "thread-2"]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)],
            gateFirstCreation: true
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        #expect(await factory.creationCount == 0)
        let first = Task { try await supervisor.startThread() }
        let second = Task { try await supervisor.startThread() }
        await factory.waitForCreationCount(1)
        #expect(await factory.creationCount == 1)
        await factory.releaseFirstCreation()

        let threadIDs = try await [first.value, second.value]
        #expect(Set(threadIDs.map(\.rawValue)) == ["thread-1", "thread-2"])
        #expect(await factory.creationCount == 1)
        #expect(await supervisor.currentAvailability == .ready)
        await supervisor.shutdown()
    }

    @Test("resuming a thread started in the current generation is idempotent")
    func currentGenerationResumeDoesNotReloadThread() async throws {
        let generation = ScriptedSupervisorGeneration(
            startedThreads: ["current-thread"]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        let threadID = try await supervisor.startThread()
        try await supervisor.resumeThread(threadID)

        #expect(await generation.recordedCalls == [.startThread])
        await supervisor.shutdown()
    }

    @Test("cancelling one startup caller preserves the shared generation")
    func cancellingStartupCallerOnlyRemovesItsWaiter() async throws {
        let generation = ScriptedSupervisorGeneration(
            startedThreads: ["thread-survivor", "thread-unexpected"]
        )
        let startupGate = CancellationAwareSupervisorStartupGate()
        let supervisor = CodexAppServerSupervisor(
            generationFactory: {
                try await startupGate.wait()
                return generation
            }
        )
        let cancelledCompletion = SupervisorCompletionProbe()
        let survivorCompletion = SupervisorCompletionProbe()

        let cancelled = Task { () -> Bool in
            let wasCancelled: Bool
            do {
                _ = try await supervisor.startThread()
                wasCancelled = false
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                wasCancelled = false
            }
            await cancelledCompletion.recordCompletion()
            return wasCancelled
        }
        let survivor = Task {
            let threadID = try await supervisor.startThread()
            await survivorCompletion.recordCompletion()
            return threadID
        }
        await startupGate.waitUntilStarted()

        cancelled.cancel()
        let cancelledReturnedBeforeStartup = await supervisorEventually {
            await cancelledCompletion.completions == 1
        }
        #expect(cancelledReturnedBeforeStartup)
        #expect(await survivorCompletion.completions == 0)
        #expect(await startupGate.startCount == 1)
        #expect(await startupGate.wasCancelled == false)

        await startupGate.open()
        #expect(await cancelled.value)
        #expect(try await survivor.value == AgentThreadID(
            rawValue: "thread-survivor"
        ))
        #expect(await startupGate.startCount == 1)
        await supervisor.shutdown()
    }

    @Test("coalesced startup failure wakes every caller without retrying")
    func coalescedStartupFailureCompletesEveryWaiter() async {
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.failure(.crashed)],
            gateFirstCreation: true
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        let first = Task { try await supervisor.startThread() }
        let second = Task { try await supervisor.startThread() }
        await factory.waitForCreationCount(1)
        await Task.yield()
        await factory.releaseFirstCreation()

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await first.value
        }
        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await second.value
        }
        #expect(await factory.creationCount == 1)
        await supervisor.shutdown()
    }

    @Test("typed startup failures publish bounded protocol-neutral availability")
    func mapsTypedStartupFailures() async {
        let cases: [(
            CodexAppServerSupervisorStartupError,
            AgentAvailability
        )] = [
            (
                .unsupportedVersion(String(repeating: "raw-secret-", count: 100)),
                .unsupportedVersion("Unsupported Codex version")
            ),
            (.authenticationRequired, .authenticationRequired),
            (
                .capabilityUnavailable(String(repeating: "raw-json-", count: 100)),
                .capabilityUnavailable("Required Codex capability unavailable")
            ),
            (.overloaded, .overloaded),
        ]

        for (failure, expected) in cases {
            let factory = ScriptedSupervisorGenerationFactory(
                outcomes: [.failure(failure)]
            )
            let supervisor = CodexAppServerSupervisor(
                generationFactory: { try await factory.makeGeneration() }
            )

            await #expect(throws: CodexAppServerSupervisorError.unavailable) {
                try await supervisor.startThread()
            }
            #expect(await supervisor.currentAvailability == expected)
            await #expect(throws: CodexAppServerSupervisorError.unavailable) {
                try await supervisor.startThread()
            }
            #expect(await factory.creationCount == 1)
            await supervisor.shutdown()
        }
    }

    @Test("crash interrupts active turns and resumes only idle mapped threads")
    func crashRecoveryDoesNotReplayActiveWork() async throws {
        let first = ScriptedSupervisorGeneration(
            startedThreads: ["thread-idle", "thread-active"],
            turnIDs: ["turn-active"]
        )
        let recovered = ScriptedSupervisorGeneration()
        let sleeper = RecordingSupervisorSleeper()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(first),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { await sleeper.sleep(for: $0) }
        )

        let idle = try await supervisor.startThread()
        let active = try await supervisor.startThread()
        let turn = try await supervisor.startTurn(
            threadID: active,
            prompt: "do not replay this prompt"
        )
        let events = await supervisor.events(for: active, after: nil)
        let failed = Task { () -> AgentEvent? in
            for await delivery in events {
                if case let .event(record) = delivery,
                    case .turnFailed = record.event
                {
                    return record.event
                }
            }
            return nil
        }

        await first.crash()
        await factory.waitForCreationCount(2)
        await recovered.waitForResumeCount(1)

        #expect(await sleeper.recordedSeconds == [1])
        #expect(
            await recovered.recordedCalls == [
                .resumeThread(idle),
            ]
        )
        #expect(
            await failed.value == .turnFailed(turn, .crashed)
        )
        #expect(await supervisor.currentAvailability == .ready)
        await supervisor.shutdown()
    }

    @Test("repeated failed recovery uses capped exponential delays")
    func exponentialRecoveryBackoff() async throws {
        let first = ScriptedSupervisorGeneration(startedThreads: ["thread-1"])
        let recovered = ScriptedSupervisorGeneration()
        let sleeper = RecordingSupervisorSleeper()
        let failures = Array(
            repeating: ScriptedSupervisorGenerationFactory.Outcome.failure(
                .crashed
            ),
            count: 6
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(first)] + failures + [.generation(recovered)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { await sleeper.sleep(for: $0) }
        )

        _ = try await supervisor.startThread()
        await first.crash()
        await factory.waitForCreationCount(8)
        await recovered.waitForResumeCount(1)

        #expect(await sleeper.recordedSeconds == [1, 2, 4, 8, 16, 30, 30])
        #expect(await supervisorEventually {
            await supervisor.currentAvailability == .ready
        })
        await supervisor.shutdown()
    }

    @Test("shutdown cancels backoff interrupts turns and reaps the generation")
    func shutdownCancelsRecovery() async throws {
        let first = ScriptedSupervisorGeneration(
            startedThreads: ["thread-1"],
            turnIDs: ["turn-1"]
        )
        let sleeper = SuspendedSupervisorSleeper()
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(first)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        let threadID = try await supervisor.startThread()
        let turnID = try await supervisor.startTurn(
            threadID: threadID,
            prompt: "active"
        )
        await first.crash()
        await sleeper.waitUntilSleeping()

        await supervisor.shutdown()
        await supervisor.shutdown()

        #expect(await sleeper.wasCancelled)
        #expect(await factory.creationCount == 1)
        #expect(await first.shutdownCount == 1)
        #expect(
            await first.recordedCalls.contains(
                .interruptTurn(threadID, turnID)
            )
        )
        #expect(await supervisor.currentAvailability == .stopped)
    }

    @Test("failed generation cleanup exclusively owns recovery admission")
    func failedCleanupBlocksReplacementAdmission() async throws {
        let failed = ScriptedSupervisorGeneration(
            startedThreads: ["thread-failed"],
            gateShutdown: true
        )
        let recovered = ScriptedSupervisorGeneration(
            startedThreads: ["thread-recovered"]
        )
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        await failed.crash()
        await failed.waitForShutdownCount(1)

        #expect(await supervisor.currentAvailability == .crashed)
        let request = Task { try await supervisor.startThread() }
        await Task.yield()
        #expect(await factory.creationCount == 1)

        await failed.releaseShutdown()
        #expect(try await request.value == AgentThreadID(
            rawValue: "thread-recovered"
        ))
        #expect(await factory.creationCount == 2)
        await supervisor.shutdown()
    }

    @Test("concurrent shutdown callers join the same gated cleanup")
    func concurrentShutdownCallersJoinCleanup() async throws {
        let generation = ScriptedSupervisorGeneration(
            startedThreads: ["thread-1"],
            gateShutdown: true
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )
        let completions = SupervisorCompletionProbe()

        _ = try await supervisor.startThread()
        let first = Task {
            await supervisor.shutdown()
            await completions.recordCompletion()
        }
        await generation.waitForShutdownCount(1)
        let second = Task {
            await supervisor.shutdown()
            await completions.recordCompletion()
        }
        await Task.yield()

        #expect(await completions.completions == 0)
        await generation.releaseShutdown()
        await first.value
        await second.value
        #expect(await completions.completions == 2)
        #expect(await generation.shutdownCount == 1)

        await supervisor.shutdown()
        #expect(await generation.shutdownCount == 1)
    }

    @Test("shutdown during failed-child cleanup joins that cleanup")
    func shutdownJoinsFailedChildCleanup() async throws {
        let failed = ScriptedSupervisorGeneration(
            startedThreads: ["thread-1"],
            gateShutdown: true
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(failed)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )
        let completion = SupervisorCompletionProbe()

        _ = try await supervisor.startThread()
        await failed.crash()
        await failed.waitForShutdownCount(1)
        let shuttingDown = Task {
            await supervisor.shutdown()
            await completion.recordCompletion()
        }
        await Task.yield()

        #expect(await completion.completions == 0)
        await failed.releaseShutdown()
        await shuttingDown.value
        #expect(await completion.completions == 1)
        #expect(await supervisor.currentAvailability == .stopped)
    }

    @Test("underlying replay gap publishes one terminal protocol failure")
    func underlyingReplayGapFailsActiveTurnExactlyOnce() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let turnID = AgentTurnID(rawValue: "turn-1")
        let generation = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue],
            turnIDs: [turnID.rawValue]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        _ = try await supervisor.startThread()
        _ = try await supervisor.startTurn(
            threadID: threadID,
            prompt: "active"
        )
        await generation.waitForEventSubscriberCount(1, threadID: threadID)
        let stream = await supervisor.events(for: threadID, after: nil)
        var iterator = stream.makeAsyncIterator()

        await generation.emit(
            .replayGap(after: 7, oldestAvailable: 10),
            for: threadID
        )
        await generation.emit(
            .replayGap(after: 7, oldestAvailable: 10),
            for: threadID
        )
        await generation.emit(
            .event(.init(
                sequence: 10,
                event: .assistantMessageDelta("after-gap")
            )),
            for: threadID
        )

        #expect(
            await iterator.next() == .event(.init(
                sequence: 1,
                event: .turnFailed(turnID, .protocolFailure)
            ))
        )
        #expect(
            await iterator.next() == .event(.init(
                sequence: 2,
                event: .assistantMessageDelta("after-gap")
            ))
        )
        await supervisor.shutdown()
    }

    @Test("late old-generation thread creation is compensated")
    func lateStartThreadDoesNotEscapeDetachedGeneration() async throws {
        let failed = ScriptedSupervisorGeneration(
            startedThreads: ["thread-late"],
            gatedCalls: [.startThread]
        )
        let recovered = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        let starting = Task { try await supervisor.startThread() }
        await failed.waitForCallStart(.startThread)
        await failed.crash()
        await factory.waitForCreationCount(2)
        await failed.release(.startThread)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await starting.value
        }
        #expect(
            await failed.recordedCalls.contains(
                .ensureThreadDeleted(.init(rawValue: "thread-late"))
            ) == false
        )
        #expect(
            await recovered.recordedCalls.contains(
                .ensureThreadDeleted(.init(rawValue: "thread-late"))
            )
        )
        await supervisor.shutdown()
    }

    @Test("failed detached cleanup never becomes a recovery mapping")
    func lateThreadCleanupFailureNeverBecomesRecoveryMapping() async throws {
        let lateThreadID = AgentThreadID(rawValue: "thread-late")
        let syncThreadID = AgentThreadID(rawValue: "thread-sync")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [lateThreadID.rawValue],
            gatedCalls: [.startThread],
            ensureThreadDeletionFailures: 1
        )
        let replacement = ScriptedSupervisorGeneration()
        let final = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(replacement),
            .generation(final),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        let starting = Task { try await supervisor.startThread() }
        await failed.waitForCallStart(.startThread)
        await failed.crash()
        await factory.waitForCreationCount(2)
        await failed.release(.startThread)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await starting.value
        }
        #expect(
            await replacement.recordedCalls.contains(
                .ensureThreadDeleted(lateThreadID)
            )
        )

        await replacement.crash()
        await factory.waitForCreationCount(3)
        try await supervisor.resumeThread(syncThreadID)

        #expect(
            await final.recordedCalls.contains(.resumeThread(lateThreadID))
                == false
        )
        await supervisor.shutdown()
    }

    @Test("failed replacement cleanup transfers the exact thread id")
    func failedReplacementCleanupTransfersExactThreadOwnership() async throws {
        let lateThreadID = AgentThreadID(rawValue: "thread-transfer")
        let syncThreadID = AgentThreadID(rawValue: "thread-sync")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [lateThreadID.rawValue],
            gatedCalls: [.startThread]
        )
        let replacement = ScriptedSupervisorGeneration(
            ensureThreadDeletionFailures: 1
        )
        let final = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(replacement),
            .generation(final),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        let starting = Task { try await supervisor.startThread() }
        await failed.waitForCallStart(.startThread)
        await failed.crash()
        await factory.waitForCreationCount(2)
        await failed.release(.startThread)

        #expect(try await starting.value == lateThreadID)
        #expect(
            await replacement.recordedCalls.contains(
                .ensureThreadDeleted(lateThreadID)
            )
        )

        await replacement.crash()
        await factory.waitForCreationCount(3)
        try await supervisor.resumeThread(syncThreadID)

        #expect(
            await final.recordedCalls.contains(.resumeThread(lateThreadID))
                == false
        )
        await supervisor.shutdown()
    }

    @Test("cancelled late start transfers ownership without waiting recovery")
    func cancelledLateStartDoesNotBlockCoordinatorShutdown() async throws {
        let lateThreadID = AgentThreadID(rawValue: "thread-cancelled")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [lateThreadID.rawValue],
            gatedCalls: [.startThread]
        )
        let sleeper = SuspendedSupervisorSleeper()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(ScriptedSupervisorGeneration()),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )
        let completion = SupervisorCompletionProbe()

        let starting = Task {
            let threadID = try await supervisor.startThread()
            await completion.recordCompletion()
            return threadID
        }
        await failed.waitForCallStart(.startThread)
        await failed.crash()
        await sleeper.waitUntilSleeping()
        starting.cancel()
        await failed.release(.startThread)

        let transferredBeforeSupervisorShutdown = await supervisorEventually {
            await completion.completions == 1
        }
        #expect(transferredBeforeSupervisorShutdown)

        await supervisor.shutdown()
        #expect(try await starting.value == lateThreadID)
    }

    @Test("cancelling one recovery waiter does not cancel shared recovery")
    func recoveryWaitersHaveExactCancellationOwnership() async throws {
        let failed = ScriptedSupervisorGeneration(startedThreads: ["owned"])
        let sleeper = SuspendedSupervisorSleeper()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(ScriptedSupervisorGeneration()),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )
        _ = try await supervisor.startThread()
        await failed.crash()
        await sleeper.waitUntilSleeping()
        let cancelledCompletion = SupervisorCompletionProbe()
        let retainedCompletion = SupervisorCompletionProbe()

        let cancelled = Task {
            do {
                _ = try await supervisor.startThread()
            } catch {}
            await cancelledCompletion.recordCompletion()
        }
        let retained = Task {
            do {
                _ = try await supervisor.startThread()
            } catch {}
            await retainedCompletion.recordCompletion()
        }
        await Task.yield()
        cancelled.cancel()

        #expect(await supervisorEventually {
            await cancelledCompletion.completions == 1
        })
        #expect(await retainedCompletion.completions == 0)
        #expect(await sleeper.wasCancelled == false)

        await supervisor.shutdown()
        await cancelled.value
        await retained.value
        #expect(await retainedCompletion.completions == 1)
        #expect(await sleeper.wasCancelled)
    }

    @Test("successful exact cleanup remains terminal after generation detach")
    func exactCleanupSuccessCannotTransferDeletedThread() async throws {
        let lateThreadID = AgentThreadID(rawValue: "thread-deleted")
        let mappingStore = CodexAppServerThreadMappingStore()
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [lateThreadID.rawValue],
            gatedCalls: [.startThread]
        )
        let replacement = ScriptedSupervisorGeneration(
            gateShutdown: true,
            gatedCalls: [.ensureThreadDeleted]
        )
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(replacement),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            mappingStore: mappingStore,
            sleeper: { _ in }
        )

        let starting = Task { try await supervisor.startThread() }
        await failed.waitForCallStart(.startThread)
        await failed.crash()
        await factory.waitForCreationCount(2)
        await failed.release(.startThread)
        await replacement.waitForCallStart(.ensureThreadDeleted)
        #expect(
            await replacement.remotelyDeletedThreadIDs.contains(lateThreadID)
        )

        await replacement.crash()
        await replacement.waitForShutdownCount(1)
        starting.cancel()
        await replacement.waitForCallCancellation(.ensureThreadDeleted)
        await replacement.release(.ensureThreadDeleted)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await starting.value
        }

        #expect(await mappingStore.contains(lateThreadID) == false)
        #expect(await factory.creationCount == 2)
        #expect(
            await replacement.recordedCalls.contains(
                .resumeThread(lateThreadID)
            )
                == false
        )

        let shuttingDown = Task { await supervisor.shutdown() }
        await replacement.releaseShutdown()
        await shuttingDown.value
    }

    @Test("late old-generation turn creation is interrupted and rejected")
    func lateStartTurnDoesNotBecomeActive() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let turnID = AgentTurnID(rawValue: "turn-late")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue],
            turnIDs: [turnID.rawValue],
            gatedCalls: [.startTurn]
        )
        let recovered = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        let starting = Task {
            try await supervisor.startTurn(threadID: threadID, prompt: "late")
        }
        await failed.waitForCallStart(.startTurn)
        await failed.crash()
        await recovered.waitForResumeCount(1)
        await failed.release(.startTurn)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await starting.value
        }
        #expect(
            await failed.recordedCalls.contains(
                .interruptTurn(threadID, turnID)
            )
        )
        await supervisor.shutdown()
    }

    @Test("late old-generation resume completion cannot commit")
    func lateResumeDoesNotMutateReplacementGeneration() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue],
            gatedCalls: [.resumeThread]
        )
        let recovered = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        let resuming = Task { try await supervisor.resumeThread(threadID) }
        await failed.waitForCallStart(.resumeThread)
        await failed.crash()
        await recovered.waitForResumeCount(1)
        await failed.release(.resumeThread)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await resuming.value
        }
        await supervisor.shutdown()
    }

    @Test("late old-generation delete cannot forget replacement mapping")
    func lateDeleteDoesNotMutateReplacementGeneration() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue],
            gatedCalls: [.deleteThread]
        )
        let recovered = ScriptedSupervisorGeneration(turnIDs: ["turn-2"])
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        let deleting = Task { try await supervisor.deleteThread(threadID) }
        await failed.waitForCallStart(.deleteThread)
        await failed.crash()
        await recovered.waitForResumeCount(1)
        await failed.release(.deleteThread)

        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await deleting.value
        }
        #expect(
            try await supervisor.startTurn(
                threadID: threadID,
                prompt: "replacement"
            ) == AgentTurnID(rawValue: "turn-2")
        )
        await supervisor.shutdown()
    }

    @Test("slow subscribers receive a replay gap before post-gap records")
    func slowSubscriberOverflowIsLossAware() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let generation = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        _ = try await supervisor.startThread()
        await generation.waitForEventSubscriberCount(1, threadID: threadID)
        let stream = await supervisor.events(for: threadID, after: nil)
        for index in 1...600 {
            await generation.emit(
                .event(.init(
                    sequence: UInt64(index),
                    event: .assistantMessageDelta("event-\(index)")
                )),
                for: threadID
            )
        }
        while await supervisor.eventSequenceForTesting(threadID) < 600 {
            await Task.yield()
        }
        var iterator = stream.makeAsyncIterator()

        #expect(
            await iterator.next() == .replayGap(
                after: nil,
                oldestAvailable: 89
            )
        )
        #expect(await iterator.next() == nil)
        await supervisor.shutdown()
    }

    @Test("dropped supervisor event streams release subscriber ownership")
    func droppedEventStreamRemovesSubscriber() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let generation = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        _ = try await supervisor.startThread()
        var stream: AsyncStream<AgentEventDelivery>? = await supervisor.events(
            for: threadID,
            after: nil
        )
        #expect(await supervisor.eventSubscriberCountForTesting == 1)
        stream = nil
        _ = stream
        while await supervisor.eventSubscriberCountForTesting != 0 {
            await Task.yield()
        }

        await supervisor.shutdown()
    }

    @Test("cancelled event iteration removes subscriber immediately")
    func cancelledEventIteratorRemovesSubscriber() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let generation = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() }
        )

        _ = try await supervisor.startThread()
        let stream = await supervisor.events(for: threadID, after: nil)
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        while await supervisor.eventSubscriberCountForTesting != 1 {
            await Task.yield()
        }
        consumer.cancel()
        _ = await consumer.value

        let removed = await supervisorEventually {
            await supervisor.eventSubscriberCountForTesting == 0
        }
        #expect(removed)
        _ = stream
        await supervisor.shutdown()
    }

    @Test("replacement crash during recovery is consumed and retried")
    func replacementCrashDuringRecoveryCannotBecomeReady() async throws {
        let threadID = AgentThreadID(rawValue: "thread-1")
        let failed = ScriptedSupervisorGeneration(
            startedThreads: [threadID.rawValue]
        )
        let crashedReplacement = ScriptedSupervisorGeneration(
            gatedCalls: [.resumeThread]
        )
        let recovered = ScriptedSupervisorGeneration()
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(crashedReplacement),
            .generation(recovered),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        await failed.crash()
        await crashedReplacement.waitForCallStart(.resumeThread)
        await crashedReplacement.crash()
        await crashedReplacement.release(.resumeThread)

        let retried = await supervisorEventually {
            await factory.creationCount == 3
        }
        #expect(retried)
        #expect(await crashedReplacement.shutdownCount == 1)
        #expect(await supervisor.currentAvailability == .ready)
        await supervisor.shutdown()
    }

    @Test("production initialize seam classifies terminal typed failures")
    func productionInitializeClassifiesTerminalFailures() async {
        let cases: [(Int, AgentAvailability)] = [
            (401, .authenticationRequired),
            (
                -32601,
                .capabilityUnavailable(
                    "Required Codex capability unavailable"
                )
            ),
            (429, .overloaded),
        ]

        for (code, expected) in cases {
            let process = ScriptedAppServerProcess()
            let adapter = CodexAppServerAdapter(
                transport: JSONLAppServerTransport(process: process),
                launchConfiguration: supervisorLaunchConfiguration(),
                toolExecutor: SupervisorNoopToolExecutor()
            )
            let supervisor = CodexAppServerSupervisor(
                generationFactory: {
                    do {
                        try await adapter.initializeForSupervision()
                        return adapter
                    } catch {
                        await adapter.shutdown()
                        throw error
                    }
                },
                sleeper: { _ in }
            )

            let starting = Task { try await supervisor.startThread() }
            await process.waitForWriteCount(1)
            await process.emit(.standardOutput(jsonLine(
                #"{"id":1,"error":{"code":\#(code),"message":"raw secret must not classify"}}"#
            )))

            await #expect(throws: CodexAppServerSupervisorError.unavailable) {
                try await starting.value
            }
            #expect(await supervisor.currentAvailability == expected)
            #expect(await process.lifecycleCounts().wait == 1)
            await supervisor.shutdown()
        }
    }

    @Test("terminal availability detaches generation without retry")
    func terminalAvailabilityStopsGeneration() async throws {
        let generation = ScriptedSupervisorGeneration(
            startedThreads: ["thread-1"]
        )
        let factory = ScriptedSupervisorGenerationFactory(
            outcomes: [.generation(generation)]
        )
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        await generation.publishAvailability(.overloaded)
        let cleaned = await supervisorEventually {
            await generation.shutdownCount == 1
        }

        #expect(cleaned)
        #expect(await supervisor.currentAvailability == .overloaded)
        await #expect(throws: CodexAppServerSupervisorError.unavailable) {
            try await supervisor.startThread()
        }
        #expect(await factory.creationCount == 1)
        await supervisor.shutdown()
    }

    @Test("explicit availability retry clears a terminal failure and probes a new generation")
    func retriesTerminalAvailabilityOnExplicitRequest() async throws {
        let failed = ScriptedSupervisorGeneration(
            startedThreads: ["thread-before-retry"]
        )
        let replacement = ScriptedSupervisorGeneration(
            startedThreads: ["thread-after-retry"]
        )
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failed),
            .generation(replacement),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )

        _ = try await supervisor.startThread()
        await failed.publishAvailability(.overloaded)
        let detached = await supervisorEventually {
            await failed.shutdownCount == 1
        }
        #expect(detached)

        await supervisor.retryAvailability()

        #expect(await factory.creationCount == 2)
        #expect(await supervisor.currentAvailability == .ready)
        #expect(try await supervisor.startThread() == AgentThreadID(
            rawValue: "thread-after-retry"
        ))
        await supervisor.shutdown()
    }
}
