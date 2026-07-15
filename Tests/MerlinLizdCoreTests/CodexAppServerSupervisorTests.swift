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
        #expect(await supervisor.currentAvailability == .ready)
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
}
