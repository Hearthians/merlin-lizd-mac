import Foundation
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

actor ScriptedSupervisorGenerationFactory {
    enum Outcome: Sendable {
        case generation(ScriptedSupervisorGeneration)
        case failure(CodexAppServerSupervisorStartupError)
    }

    private var outcomes: [Outcome]
    private let gateFirstCreation: Bool
    private var firstCreationGate: CheckedContinuation<Void, Never>?
    private var creationWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private(set) var creationCount = 0

    init(outcomes: [Outcome], gateFirstCreation: Bool = false) {
        self.outcomes = outcomes
        self.gateFirstCreation = gateFirstCreation
    }

    func makeGeneration() async throws -> any CodexAgentClient {
        creationCount += 1
        resumeCreationWaiters()
        if gateFirstCreation, creationCount == 1 {
            await withCheckedContinuation { firstCreationGate = $0 }
        }
        guard !outcomes.isEmpty else {
            throw CodexAppServerSupervisorStartupError.crashed
        }
        switch outcomes.removeFirst() {
        case let .generation(generation):
            return generation
        case let .failure(error):
            throw error
        }
    }

    func waitForCreationCount(_ count: Int) async {
        if creationCount >= count { return }
        await withCheckedContinuation { creationWaiters.append((count, $0)) }
    }

    func releaseFirstCreation() {
        firstCreationGate?.resume()
        firstCreationGate = nil
    }

    private func resumeCreationWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in creationWaiters {
            if creationCount >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        creationWaiters = retained
    }
}

actor ScriptedSupervisorGeneration: CodexAgentClient {
    enum Call: Equatable, Sendable {
        case startThread
        case resumeThread(AgentThreadID)
        case startTurn(AgentThreadID, String)
        case steerTurn(AgentThreadID, AgentTurnID, String)
        case interruptTurn(AgentThreadID, AgentTurnID)
        case archiveThread(AgentThreadID)
        case unarchiveThread(AgentThreadID)
        case deleteThread(AgentThreadID)
        case ensureThreadDeleted(AgentThreadID)
    }

    private var startedThreads: [String]
    private var turnIDs: [String]
    private var eventContinuations: [
        AgentThreadID: [UUID: AsyncStream<AgentEventDelivery>.Continuation]
    ] = [:]
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var resumeWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private(set) var recordedCalls: [Call] = []
    private(set) var shutdownCount = 0

    init(startedThreads: [String] = [], turnIDs: [String] = []) {
        self.startedThreads = startedThreads
        self.turnIDs = turnIDs
    }

    func startThread() throws -> AgentThreadID {
        recordedCalls.append(.startThread)
        guard !startedThreads.isEmpty else {
            throw CodexAppServerSupervisorError.unavailable
        }
        return AgentThreadID(rawValue: startedThreads.removeFirst())
    }

    func resumeThread(_ threadID: AgentThreadID) {
        recordedCalls.append(.resumeThread(threadID))
        resumeResumeWaiters()
    }

    func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) throws -> AgentTurnID {
        recordedCalls.append(.startTurn(threadID, prompt))
        guard !turnIDs.isEmpty else {
            throw CodexAppServerSupervisorError.unavailable
        }
        return AgentTurnID(rawValue: turnIDs.removeFirst())
    }

    func steerTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        prompt: String
    ) {
        recordedCalls.append(.steerTurn(threadID, turnID, prompt))
    }

    func interruptTurn(threadID: AgentThreadID, turnID: AgentTurnID) {
        recordedCalls.append(.interruptTurn(threadID, turnID))
    }

    func events(
        for threadID: AgentThreadID,
        after sequence: UInt64?
    ) -> AsyncStream<AgentEventDelivery> {
        let id = UUID()
        let pair = AsyncStream<AgentEventDelivery>.makeStream()
        eventContinuations[threadID, default: [:]][id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id, threadID: threadID) }
        }
        return pair.stream
    }

    func availability() -> AsyncStream<AgentAvailability> {
        let id = UUID()
        let pair = AsyncStream<AgentAvailability>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.yield(.ready)
        availabilityContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAvailabilityContinuation(id) }
        }
        return pair.stream
    }

    func archiveThread(_ threadID: AgentThreadID) {
        recordedCalls.append(.archiveThread(threadID))
    }

    func unarchiveThread(_ threadID: AgentThreadID) {
        recordedCalls.append(.unarchiveThread(threadID))
    }

    func deleteThread(_ threadID: AgentThreadID) {
        recordedCalls.append(.deleteThread(threadID))
    }

    func ensureThreadDeleted(_ threadID: AgentThreadID) {
        recordedCalls.append(.ensureThreadDeleted(threadID))
    }

    func shutdown() {
        shutdownCount += 1
        for continuations in eventContinuations.values {
            continuations.values.forEach { $0.finish() }
        }
        eventContinuations.removeAll()
        availabilityContinuations.values.forEach { $0.finish() }
        availabilityContinuations.removeAll()
    }

    func crash() {
        availabilityContinuations.values.forEach { $0.yield(.crashed) }
    }

    func waitForResumeCount(_ count: Int) async {
        if resumeCount >= count { return }
        await withCheckedContinuation { resumeWaiters.append((count, $0)) }
    }

    private var resumeCount: Int {
        recordedCalls.reduce(0) { count, call in
            if case .resumeThread = call { count + 1 } else { count }
        }
    }

    private func resumeResumeWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in resumeWaiters {
            if resumeCount >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        resumeWaiters = retained
    }

    private func removeEventContinuation(
        _ id: UUID,
        threadID: AgentThreadID
    ) {
        eventContinuations[threadID]?.removeValue(forKey: id)
    }

    private func removeAvailabilityContinuation(_ id: UUID) {
        availabilityContinuations.removeValue(forKey: id)
    }
}

actor RecordingSupervisorSleeper {
    private(set) var recordedSeconds: [Int64] = []

    func sleep(for duration: Duration) {
        recordedSeconds.append(duration.components.seconds)
    }
}

actor SuspendedSupervisorSleeper {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func sleep(for duration: Duration) async throws {
        _ = duration
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilSleeping() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
