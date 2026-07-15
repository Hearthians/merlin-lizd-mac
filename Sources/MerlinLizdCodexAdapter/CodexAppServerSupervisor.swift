import Foundation
import MerlinLizdCore

public enum CodexAppServerSupervisorStartupError: Error, Equatable, Sendable {
    case unsupportedVersion(String)
    case authenticationRequired
    case capabilityUnavailable(String)
    case overloaded
    case crashed
}

public enum CodexAppServerSupervisorError: Error, Equatable, Sendable {
    case unavailable
    case stopped
}

/// Keeps the Core-facing client stable while app-server process generations
/// are replaced. The supervisor owns recovery timing; each adapter generation
/// continues to own its transport requests, tool calls, stdin, and child reap.
public actor CodexAppServerSupervisor: CodexAgentClient {
    public typealias GenerationFactory = @Sendable () async throws
        -> any CodexAgentClient
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct Generation: Sendable {
        let id: UUID
        let client: any CodexAgentClient
    }

    private struct StartupOperation: Sendable {
        let id: UUID
        let task: Task<any CodexAgentClient, any Error>
    }

    private struct EventForwarder: Sendable {
        let generationID: UUID
        let task: Task<Void, Never>
    }

    private static let replayLimit = 512
    private static let restartSeconds: [Int64] = [1, 2, 4, 8, 16, 30]

    private let generationFactory: GenerationFactory
    private let sleeper: Sleeper
    private let mappingStore: CodexAppServerThreadMappingStore?

    private var generation: Generation?
    private var generationThreadIDs: Set<AgentThreadID> = []
    private var startupOperation: StartupOperation?
    private var availabilitySetupTask: Task<
        AsyncStream<AgentAvailability>, Never
    >?
    private var availabilityObserver: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var mappedThreadIDs: Set<AgentThreadID> = []
    private var activeTurns: [AgentThreadID: AgentTurnID] = [:]
    private var eventForwarders: [AgentThreadID: EventForwarder] = [:]
    private var eventSequences: [AgentThreadID: UInt64] = [:]
    private var eventReplay: [AgentThreadID: [AgentEventRecord]] = [:]
    private var eventContinuations: [
        AgentThreadID: [UUID: AsyncStream<AgentEventDelivery>.Continuation]
    ] = [:]
    private var availabilityValue: AgentAvailability = .starting
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var stopped = false

    public init(
        generationFactory: @escaping GenerationFactory,
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.generationFactory = generationFactory
        self.sleeper = sleeper
        mappingStore = nil
    }

    public init(
        resolver: CodexExecutableResolver = CodexExecutableResolver(),
        runtimeDirectory: URL,
        toolExecutor: any CodexDynamicToolExecuting,
        mappingStore: CodexAppServerThreadMappingStore = .init(),
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.mappingStore = mappingStore
        self.sleeper = sleeper
        generationFactory = {
            let resolved: ResolvedCodexExecutable
            do {
                resolved = try await resolver.resolve()
            } catch let error as CodexExecutableResolverError {
                switch error {
                case let .unsupportedVersion(version):
                    throw CodexAppServerSupervisorStartupError
                        .unsupportedVersion(version)
                case .notFound, .malformedVersion:
                    throw CodexAppServerSupervisorStartupError
                        .capabilityUnavailable("Codex executable unavailable")
                case .probeTimedOut, .versionProbeFailed, .probeBusy:
                    throw CodexAppServerSupervisorStartupError.crashed
                }
            }
            return CodexAppServerAdapter(
                launchConfiguration: CodexLaunchConfiguration(
                    executable: resolved.executable,
                    runtimeDirectory: runtimeDirectory
                ),
                toolExecutor: toolExecutor,
                mappingStore: mappingStore
            )
        }
    }

    public func startThread() async throws -> AgentThreadID {
        let client = try await readyClient()
        do {
            let threadID = try await client.startThread()
            mappedThreadIDs.insert(threadID)
            generationThreadIDs.insert(threadID)
            installEventForwarder(threadID: threadID)
            setAvailability(.ready)
            return threadID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func resumeThread(_ threadID: AgentThreadID) async throws {
        let client = try await readyClient()
        await mappingStore?.insert(threadID)
        do {
            try await client.resumeThread(threadID)
            mappedThreadIDs.insert(threadID)
            generationThreadIDs.insert(threadID)
            installEventForwarder(threadID: threadID)
            setAvailability(.ready)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) async throws -> AgentTurnID {
        let client = try await readyClient()
        try await loadMappedThreadIfNeeded(threadID, client: client)
        do {
            let turnID = try await client.startTurn(
                threadID: threadID,
                prompt: prompt
            )
            activeTurns[threadID] = turnID
            setAvailability(.ready)
            return turnID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func steerTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        prompt: String
    ) async throws {
        guard activeTurns[threadID] == turnID else {
            throw CodexAppServerSupervisorError.unavailable
        }
        let client = try await readyClient()
        do {
            try await client.steerTurn(
                threadID: threadID,
                turnID: turnID,
                prompt: prompt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func interruptTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async {
        guard !stopped, let client = generation?.client else { return }
        await client.interruptTurn(threadID: threadID, turnID: turnID)
    }

    public func events(
        for threadID: AgentThreadID,
        after sequence: UInt64?
    ) -> AsyncStream<AgentEventDelivery> {
        guard !stopped else { return AsyncStream { $0.finish() } }
        let id = UUID()
        let pair = AsyncStream<AgentEventDelivery>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let replay = eventReplay[threadID] ?? []
        if let oldest = replay.first?.sequence,
            isReplayGap(oldest: oldest, after: sequence)
        {
            pair.continuation.yield(.replayGap(
                after: sequence,
                oldestAvailable: oldest
            ))
            pair.continuation.finish()
            return pair.stream
        }
        let retained = replay.filter { record in
            sequence.map { record.sequence > $0 } ?? true
        }
        if !retained.isEmpty { pair.continuation.yield(.events(retained)) }
        eventContinuations[threadID, default: [:]][id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id, threadID: threadID) }
        }
        return pair.stream
    }

    public func availability() -> AsyncStream<AgentAvailability> {
        let id = UUID()
        let pair = AsyncStream<AgentAvailability>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.yield(availabilityValue)
        guard !stopped else {
            pair.continuation.finish()
            return pair.stream
        }
        availabilityContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAvailabilityContinuation(id) }
        }
        return pair.stream
    }

    public func archiveThread(_ threadID: AgentThreadID) async throws {
        let client = try await readyClient()
        try await loadMappedThreadIfNeeded(threadID, client: client)
        do {
            try await client.archiveThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func unarchiveThread(_ threadID: AgentThreadID) async throws {
        let client = try await readyClient()
        try await loadMappedThreadIfNeeded(threadID, client: client)
        do {
            try await client.unarchiveThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func deleteThread(_ threadID: AgentThreadID) async throws {
        let client = try await readyClient()
        try await loadMappedThreadIfNeeded(threadID, client: client)
        do {
            try await client.deleteThread(threadID)
            forgetThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func ensureThreadDeleted(_ threadID: AgentThreadID) async throws {
        let client = try await readyClient()
        await mappingStore?.insert(threadID)
        do {
            try await client.ensureThreadDeleted(threadID)
            forgetThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        let recovery = restartTask
        restartTask = nil
        recovery?.cancel()
        let startup = startupOperation
        startupOperation = nil
        startup?.task.cancel()
        availabilityObserver?.cancel()
        availabilityObserver = nil
        availabilitySetupTask?.cancel()
        availabilitySetupTask = nil
        let forwarders = eventForwarders.values.map(\.task)
        eventForwarders.removeAll()
        forwarders.forEach { $0.cancel() }

        if let recovery { await recovery.value }
        if let startup,
            let uninstalled = try? await startup.task.value,
            generation == nil
        {
            await uninstalled.shutdown()
        }
        if let generation {
            for (threadID, turnID) in activeTurns {
                await generation.client.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
            }
            await generation.client.shutdown()
        }
        for task in forwarders { await task.value }
        generation = nil
        generationThreadIDs.removeAll()
        activeTurns.removeAll()
        mappedThreadIDs.removeAll()
        setAvailability(.stopped)
        finishStreams()
    }

    var currentAvailability: AgentAvailability { availabilityValue }

    private func readyClient() async throws -> any CodexAgentClient {
        guard !stopped else { throw CodexAppServerSupervisorError.stopped }
        if let generation {
            if let setup = availabilitySetupTask { _ = await setup.value }
            return generation.client
        }
        if let recovery = restartTask {
            await recovery.value
            guard !stopped, let generation else {
                throw CodexAppServerSupervisorError.unavailable
            }
            return generation.client
        }

        let operation: StartupOperation
        if let current = startupOperation {
            operation = current
        } else {
            setAvailability(.starting)
            let factory = generationFactory
            let created = StartupOperation(
                id: UUID(),
                task: Task { try await factory() }
            )
            startupOperation = created
            operation = created
        }

        do {
            let client = try await operation.task.value
            guard !stopped else {
                await client.shutdown()
                throw CodexAppServerSupervisorError.stopped
            }
            if let generation {
                if let setup = availabilitySetupTask { _ = await setup.value }
                return generation.client
            }
            guard startupOperation?.id == operation.id else {
                await client.shutdown()
                throw CodexAppServerSupervisorError.unavailable
            }
            startupOperation = nil
            let installed = installGeneration(client)
            if let setup = availabilitySetupTask { _ = await setup.value }
            return installed.client
        } catch is CancellationError {
            if startupOperation?.id == operation.id { startupOperation = nil }
            throw CancellationError()
        } catch {
            if startupOperation?.id == operation.id { startupOperation = nil }
            setAvailability(availability(for: error))
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    private func installGeneration(
        _ client: any CodexAgentClient
    ) -> Generation {
        let installed = Generation(id: UUID(), client: client)
        generation = installed
        generationThreadIDs.removeAll()
        let setup = Task { await client.availability() }
        availabilitySetupTask = setup
        let streamTask = Task { [weak self, setup] in
            let stream = await setup.value
            for await value in stream {
                guard !Task.isCancelled else { return }
                await self?.receiveAvailability(
                    value,
                    generationID: installed.id
                )
            }
        }
        availabilityObserver = streamTask
        return installed
    }

    private func loadMappedThreadIfNeeded(
        _ threadID: AgentThreadID,
        client: any CodexAgentClient
    ) async throws {
        guard !generationThreadIDs.contains(threadID) else { return }
        guard mappedThreadIDs.contains(threadID) else {
            throw CodexAppServerSupervisorError.unavailable
        }
        await mappingStore?.insert(threadID)
        do {
            try await client.resumeThread(threadID)
            generationThreadIDs.insert(threadID)
            installEventForwarder(threadID: threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    private func installEventForwarder(threadID: AgentThreadID) {
        guard let generation else { return }
        if eventForwarders[threadID]?.generationID == generation.id { return }
        eventForwarders[threadID]?.task.cancel()
        let after = eventSequences[threadID]
        let client = generation.client
        let generationID = generation.id
        let task = Task { [weak self, client] in
            let stream = await client.events(for: threadID, after: nil)
            for await delivery in stream {
                guard !Task.isCancelled else { return }
                await self?.forward(
                    delivery,
                    threadID: threadID,
                    generationID: generationID,
                    priorSequence: after
                )
            }
        }
        eventForwarders[threadID] = EventForwarder(
            generationID: generationID,
            task: task
        )
    }

    private func forward(
        _ delivery: AgentEventDelivery,
        threadID: AgentThreadID,
        generationID: UUID,
        priorSequence: UInt64?
    ) {
        _ = priorSequence
        guard generation?.id == generationID else { return }
        switch delivery {
        case let .event(record):
            publish(record.event, for: threadID)
        case let .events(records):
            for record in records { publish(record.event, for: threadID) }
        case .replayGap:
            if let turnID = activeTurns.removeValue(forKey: threadID) {
                publish(.turnFailed(turnID, .protocolFailure), for: threadID)
            }
        }
    }

    private func receiveAvailability(
        _ value: AgentAvailability,
        generationID: UUID
    ) async {
        guard generation?.id == generationID, !stopped else { return }
        switch value {
        case .crashed:
            await generationCrashed(generationID)
        case .unsupportedVersion:
            setAvailability(.unsupportedVersion("Unsupported Codex version"))
        case .capabilityUnavailable:
            setAvailability(.capabilityUnavailable(
                "Required Codex capability unavailable"
            ))
        case .authenticationRequired:
            setAvailability(.authenticationRequired)
        case .overloaded:
            setAvailability(.overloaded)
        case .ready:
            setAvailability(.ready)
        case .starting:
            setAvailability(.starting)
        case .stopped:
            break
        }
    }

    private func generationCrashed(_ generationID: UUID) async {
        guard let failed = generation, failed.id == generationID,
            restartTask == nil, !stopped
        else { return }
        generation = nil
        generationThreadIDs.removeAll()
        availabilityObserver?.cancel()
        availabilityObserver = nil
        availabilitySetupTask?.cancel()
        availabilitySetupTask = nil
        let forwarders = eventForwarders.values.map(\.task)
        eventForwarders.removeAll()
        forwarders.forEach { $0.cancel() }
        let interrupted = activeTurns
        for (threadID, turnID) in interrupted {
            await failed.client.interruptTurn(
                threadID: threadID,
                turnID: turnID
            )
            publish(.turnFailed(turnID, .crashed), for: threadID)
        }
        await failed.client.shutdown()
        setAvailability(.crashed)
        guard !stopped else { return }
        let excluded = Set(interrupted.keys)
        restartTask = Task { [weak self] in
            await self?.recover(excluding: excluded)
        }
    }

    private func recover(excluding excluded: Set<AgentThreadID>) async {
        var attempt = 0
        while !Task.isCancelled, !stopped {
            let delayIndex = min(attempt, Self.restartSeconds.count - 1)
            let delay = Duration.seconds(Self.restartSeconds[delayIndex])
            do {
                try await sleeper(delay)
                try Task.checkCancellation()
                let client = try await generationFactory()
                guard !Task.isCancelled, !stopped else {
                    await client.shutdown()
                    return
                }
                let installed = installGeneration(client)
                if let setup = availabilitySetupTask { _ = await setup.value }
                do {
                    for threadID in mappedThreadIDs.subtracting(excluded) {
                        await mappingStore?.insert(threadID)
                        try await installed.client.resumeThread(threadID)
                        generationThreadIDs.insert(threadID)
                        installEventForwarder(threadID: threadID)
                    }
                    setAvailability(.ready)
                    restartTask = nil
                    return
                } catch {
                    if generation?.id == installed.id { generation = nil }
                    generationThreadIDs.removeAll()
                    availabilityObserver?.cancel()
                    availabilityObserver = nil
                    availabilitySetupTask?.cancel()
                    availabilitySetupTask = nil
                    await installed.client.shutdown()
                    setAvailability(.crashed)
                }
            } catch is CancellationError {
                return
            } catch {
                let mapped = availability(for: error)
                setAvailability(mapped)
                switch mapped {
                case .crashed:
                    break
                default:
                    restartTask = nil
                    return
                }
            }
            attempt += 1
        }
        restartTask = nil
    }

    private func availability(for error: any Error) -> AgentAvailability {
        guard let startup = error as? CodexAppServerSupervisorStartupError else {
            return .crashed
        }
        switch startup {
        case .unsupportedVersion:
            return .unsupportedVersion("Unsupported Codex version")
        case .authenticationRequired:
            return .authenticationRequired
        case .capabilityUnavailable:
            return .capabilityUnavailable(
                "Required Codex capability unavailable"
            )
        case .overloaded:
            return .overloaded
        case .crashed:
            return .crashed
        }
    }

    private func publish(_ event: AgentEvent, for threadID: AgentThreadID) {
        switch event {
        case let .turnStarted(turnID):
            activeTurns[threadID] = turnID
        case let .turnCompleted(turnID):
            guard activeTurns[threadID] == turnID else { return }
            activeTurns.removeValue(forKey: threadID)
        case let .turnFailed(turnID, _):
            if let turnID {
                guard activeTurns[threadID] == turnID else { return }
            }
            activeTurns.removeValue(forKey: threadID)
        default:
            break
        }
        let sequence = eventSequences[threadID, default: 0] + 1
        eventSequences[threadID] = sequence
        let record = AgentEventRecord(sequence: sequence, event: event)
        var replay = eventReplay[threadID, default: []]
        replay.append(record)
        if replay.count > Self.replayLimit {
            replay.removeFirst(replay.count - Self.replayLimit)
        }
        eventReplay[threadID] = replay
        for continuation in eventContinuations[threadID]?.values ?? [:].values {
            continuation.yield(.event(record))
        }
    }

    private func forgetThread(_ threadID: AgentThreadID) {
        mappedThreadIDs.remove(threadID)
        generationThreadIDs.remove(threadID)
        activeTurns.removeValue(forKey: threadID)
        eventForwarders.removeValue(forKey: threadID)?.task.cancel()
        eventReplay.removeValue(forKey: threadID)
        eventSequences.removeValue(forKey: threadID)
        let continuations = eventContinuations.removeValue(forKey: threadID)
        continuations?.values.forEach { $0.finish() }
    }

    private func isReplayGap(oldest: UInt64, after cursor: UInt64?) -> Bool {
        guard let cursor else { return oldest > 1 }
        guard cursor < UInt64.max else { return false }
        return oldest > cursor + 1
    }

    private func setAvailability(_ value: AgentAvailability) {
        guard availabilityValue != value else { return }
        availabilityValue = value
        for continuation in availabilityContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeEventContinuation(
        _ id: UUID,
        threadID: AgentThreadID
    ) {
        eventContinuations[threadID]?.removeValue(forKey: id)
        if eventContinuations[threadID]?.isEmpty == true {
            eventContinuations.removeValue(forKey: threadID)
        }
    }

    private func removeAvailabilityContinuation(_ id: UUID) {
        availabilityContinuations.removeValue(forKey: id)
    }

    private func finishStreams() {
        for continuations in eventContinuations.values {
            continuations.values.forEach { $0.finish() }
        }
        eventContinuations.removeAll()
        availabilityContinuations.values.forEach { $0.finish() }
        availabilityContinuations.removeAll()
    }
}
