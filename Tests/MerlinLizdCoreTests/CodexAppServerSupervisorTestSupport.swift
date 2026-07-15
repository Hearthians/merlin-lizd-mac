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
    enum Gate: Hashable, Sendable {
        case startThread
        case resumeThread
        case startTurn
        case deleteThread
        case ensureThreadDeleted
    }

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
    private var eventSubscriberWaiters: [
        (AgentThreadID, Int, CheckedContinuation<Void, Never>)
    ] = []
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var availabilityValue: AgentAvailability
    private var resumeWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private let gateShutdown: Bool
    private var shutdownGates: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private let gatedCalls: Set<Gate>
    private var ensureThreadDeletionFailures: Int
    private var callStartCounts: [Gate: Int] = [:]
    private var callGates: [Gate: [CheckedContinuation<Void, Never>]] = [:]
    private var callStartWaiters: [
        (Gate, Int, CheckedContinuation<Void, Never>)
    ] = []
    private var callCancellationCounts: [Gate: Int] = [:]
    private var callCancellationWaiters: [
        (Gate, Int, CheckedContinuation<Void, Never>)
    ] = []
    private(set) var recordedCalls: [Call] = []
    private(set) var remotelyDeletedThreadIDs: Set<AgentThreadID> = []
    private(set) var shutdownCount = 0

    init(
        startedThreads: [String] = [],
        turnIDs: [String] = [],
        gateShutdown: Bool = false,
        gatedCalls: Set<Gate> = [],
        ensureThreadDeletionFailures: Int = 0,
        availability: AgentAvailability = .ready
    ) {
        self.startedThreads = startedThreads
        self.turnIDs = turnIDs
        self.gateShutdown = gateShutdown
        self.gatedCalls = gatedCalls
        self.ensureThreadDeletionFailures = ensureThreadDeletionFailures
        availabilityValue = availability
    }

    func startThread() async throws -> AgentThreadID {
        recordedCalls.append(.startThread)
        await suspendIfGated(.startThread)
        guard !startedThreads.isEmpty else {
            throw CodexAppServerSupervisorError.unavailable
        }
        return AgentThreadID(rawValue: startedThreads.removeFirst())
    }

    func resumeThread(_ threadID: AgentThreadID) async {
        recordedCalls.append(.resumeThread(threadID))
        resumeResumeWaiters()
        await suspendIfGated(.resumeThread)
    }

    func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) async throws -> AgentTurnID {
        recordedCalls.append(.startTurn(threadID, prompt))
        await suspendIfGated(.startTurn)
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
        resumeEventSubscriberWaiters()
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
        pair.continuation.yield(availabilityValue)
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

    func deleteThread(_ threadID: AgentThreadID) async {
        recordedCalls.append(.deleteThread(threadID))
        await suspendIfGated(.deleteThread)
    }

    func ensureThreadDeleted(_ threadID: AgentThreadID) async throws {
        recordedCalls.append(.ensureThreadDeleted(threadID))
        if ensureThreadDeletionFailures > 0 {
            ensureThreadDeletionFailures -= 1
            throw CodexAppServerSupervisorError.unavailable
        }
        remotelyDeletedThreadIDs.insert(threadID)
        await suspendIfGated(.ensureThreadDeleted)
    }

    func shutdown() async {
        shutdownCount += 1
        resumeShutdownWaiters()
        if gateShutdown {
            await withCheckedContinuation { shutdownGates.append($0) }
        }
        for continuations in eventContinuations.values {
            continuations.values.forEach { $0.finish() }
        }
        eventContinuations.removeAll()
        availabilityContinuations.values.forEach { $0.finish() }
        availabilityContinuations.removeAll()
    }

    func crash() {
        availabilityValue = .crashed
        availabilityContinuations.values.forEach { $0.yield(.crashed) }
    }

    func publishAvailability(_ value: AgentAvailability) {
        availabilityValue = value
        availabilityContinuations.values.forEach { $0.yield(value) }
    }

    func emit(
        _ delivery: AgentEventDelivery,
        for threadID: AgentThreadID
    ) {
        eventContinuations[threadID]?.values.forEach {
            $0.yield(delivery)
        }
    }

    func waitForEventSubscriberCount(
        _ count: Int,
        threadID: AgentThreadID
    ) async {
        if eventContinuations[threadID, default: [:]].count >= count { return }
        await withCheckedContinuation {
            eventSubscriberWaiters.append((threadID, count, $0))
        }
    }

    func waitForShutdownCount(_ count: Int) async {
        if shutdownCount >= count { return }
        await withCheckedContinuation { shutdownWaiters.append((count, $0)) }
    }

    func releaseShutdown() {
        let gates = shutdownGates
        shutdownGates.removeAll()
        gates.forEach { $0.resume() }
    }

    func waitForCallStart(_ gate: Gate, count: Int = 1) async {
        if callStartCounts[gate, default: 0] >= count { return }
        await withCheckedContinuation {
            callStartWaiters.append((gate, count, $0))
        }
    }

    func waitForCallCancellation(_ gate: Gate, count: Int = 1) async {
        if callCancellationCounts[gate, default: 0] >= count { return }
        await withCheckedContinuation {
            callCancellationWaiters.append((gate, count, $0))
        }
    }

    func release(_ gate: Gate) {
        let gates = callGates.removeValue(forKey: gate) ?? []
        gates.forEach { $0.resume() }
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

    private func resumeShutdownWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in shutdownWaiters {
            if shutdownCount >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        shutdownWaiters = retained
    }

    private func resumeEventSubscriberWaiters() {
        var retained: [(
            AgentThreadID,
            Int,
            CheckedContinuation<Void, Never>
        )] = []
        for waiter in eventSubscriberWaiters {
            if eventContinuations[waiter.0, default: [:]].count >= waiter.1 {
                waiter.2.resume()
            } else {
                retained.append(waiter)
            }
        }
        eventSubscriberWaiters = retained
    }

    private func suspendIfGated(_ gate: Gate) async {
        callStartCounts[gate, default: 0] += 1
        resumeCallStartWaiters()
        guard gatedCalls.contains(gate) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                callGates[gate, default: []].append($0)
            }
        } onCancel: {
            Task { await self.recordCallCancellation(gate) }
        }
    }

    private func recordCallCancellation(_ gate: Gate) {
        callCancellationCounts[gate, default: 0] += 1
        var retained: [(Gate, Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCancellationWaiters {
            if waiter.0 == gate,
                callCancellationCounts[gate, default: 0] >= waiter.1
            {
                waiter.2.resume()
            } else {
                retained.append(waiter)
            }
        }
        callCancellationWaiters = retained
    }

    private func resumeCallStartWaiters() {
        var retained: [(Gate, Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callStartWaiters {
            if callStartCounts[waiter.0, default: 0] >= waiter.1 {
                waiter.2.resume()
            } else {
                retained.append(waiter)
            }
        }
        callStartWaiters = retained
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

actor SupervisorCompletionProbe {
    private(set) var completions = 0

    func recordCompletion() { completions += 1 }
}

func supervisorEventually(
    timeout: Duration = .milliseconds(200),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

struct SupervisorNoopToolExecutor: CodexDynamicToolExecuting {
    func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        .inputAccepted(.init(acceptedRevision: 1, byteCount: 0))
    }
}

func supervisorLaunchConfiguration() -> CodexLaunchConfiguration {
    CodexLaunchConfiguration(
        executable: testURL("/codex"),
        runtimeDirectory: testURL("/runtime"),
        environment: [:]
    )
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
