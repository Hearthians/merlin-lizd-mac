import Foundation
import MerlinLizdCore

private final class SupervisorEventSubscriptionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func keepAlive() {}

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit { cancel() }
}

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

    private struct RecoveryOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    private enum LateThreadCompensation {
        case deleted
        case transferred
    }

    private struct EventSubscriber {
        var cursor: UInt64?
        var waiters: [UUID: CheckedContinuation<Void, Never>]
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
        AgentAvailability?, Never
    >?
    private var availabilityObserver: Task<Void, Never>?
    private var recoveryOperation: RecoveryOperation?
    private var shutdownTask: Task<Void, Never>?
    private var mappedThreadIDs: Set<AgentThreadID> = []
    private var pendingCompensationThreadIDs: Set<AgentThreadID> = []
    private var activeTurns: [AgentThreadID: AgentTurnID] = [:]
    private var eventForwarders: [AgentThreadID: EventForwarder] = [:]
    private var eventSequences: [AgentThreadID: UInt64] = [:]
    private var eventReplay: [AgentThreadID: [AgentEventRecord]] = [:]
    private var eventSubscribers: [
        AgentThreadID: [UUID: EventSubscriber]
    ] = [:]
    private var availabilityValue: AgentAvailability = .starting
    private var terminalAvailability: AgentAvailability?
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var stopped = false

    public init(
        generationFactory: @escaping GenerationFactory,
        mappingStore: CodexAppServerThreadMappingStore? = nil,
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.generationFactory = generationFactory
        self.sleeper = sleeper
        self.mappingStore = mappingStore
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
            let adapter = CodexAppServerAdapter(
                launchConfiguration: CodexLaunchConfiguration(
                    executable: resolved.executable,
                    runtimeDirectory: runtimeDirectory
                ),
                toolExecutor: toolExecutor,
                mappingStore: mappingStore
            )
            do {
                try await adapter.initializeForSupervision()
                return adapter
            } catch {
                await adapter.shutdown()
                throw error
            }
        }
    }

    public func startThread() async throws -> AgentThreadID {
        let handle = try await readyGeneration()
        do {
            let threadID = try await handle.client.startThread()
            guard owns(handle) else {
                switch await compensateLateThread(threadID) {
                case .deleted:
                    throw CodexAppServerSupervisorError.unavailable
                case .transferred:
                    return threadID
                }
            }
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
        let handle = try await readyGeneration()
        await mappingStore?.insert(threadID)
        guard owns(handle) else {
            throw CodexAppServerSupervisorError.unavailable
        }
        do {
            try await handle.client.resumeThread(threadID)
            guard owns(handle) else {
                throw CodexAppServerSupervisorError.unavailable
            }
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
        let handle = try await readyGeneration()
        try await loadMappedThreadIfNeeded(threadID, handle: handle)
        do {
            let turnID = try await handle.client.startTurn(
                threadID: threadID,
                prompt: prompt
            )
            guard owns(handle) else {
                await handle.client.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                throw CodexAppServerSupervisorError.unavailable
            }
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
        let handle = try await readyGeneration()
        do {
            try await handle.client.steerTurn(
                threadID: threadID,
                turnID: turnID,
                prompt: prompt
            )
            guard owns(handle), activeTurns[threadID] == turnID else {
                throw CodexAppServerSupervisorError.unavailable
            }
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
        guard !stopped else { return AsyncStream(unfolding: { nil }) }
        let id = UUID()
        eventSubscribers[threadID, default: [:]][id] = EventSubscriber(
            cursor: sequence,
            waiters: [:]
        )
        let lifetime = SupervisorEventSubscriptionLifetime { [weak self] in
            Task { await self?.cancelEventSubscriber(id, for: threadID) }
        }
        return AsyncStream(unfolding: { [weak self, lifetime] in
            lifetime.keepAlive()
            return await self?.nextEventDelivery(
                id: id,
                waiterID: UUID(),
                for: threadID
            )
        })
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
        let handle = try await readyGeneration()
        try await loadMappedThreadIfNeeded(threadID, handle: handle)
        do {
            try await handle.client.archiveThread(threadID)
            guard owns(handle) else {
                throw CodexAppServerSupervisorError.unavailable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func unarchiveThread(_ threadID: AgentThreadID) async throws {
        let handle = try await readyGeneration()
        try await loadMappedThreadIfNeeded(threadID, handle: handle)
        do {
            try await handle.client.unarchiveThread(threadID)
            guard owns(handle) else {
                throw CodexAppServerSupervisorError.unavailable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func deleteThread(_ threadID: AgentThreadID) async throws {
        let handle = try await readyGeneration()
        try await loadMappedThreadIfNeeded(threadID, handle: handle)
        do {
            try await handle.client.deleteThread(threadID)
            guard owns(handle) else {
                throw CodexAppServerSupervisorError.unavailable
            }
            forgetThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func ensureThreadDeleted(_ threadID: AgentThreadID) async throws {
        let handle = try await readyGeneration()
        await mappingStore?.insert(threadID)
        guard owns(handle) else {
            throw CodexAppServerSupervisorError.unavailable
        }
        do {
            try await handle.client.ensureThreadDeleted(threadID)
            // This exact, idempotent RPC confirms the remote ID is absent.
            // A later generation detach cannot undo that terminal result, so
            // unlike mutable operations it must not be rejected by a token
            // check after the response.
            await mappingStore?.remove(threadID)
            forgetThread(threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        stopped = true
        let recovery = detachRecovery()
        recovery?.task.cancel()
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
        let currentGeneration = generation
        generation = nil
        let cleanup = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performShutdown(
                recovery: recovery,
                startup: startup,
                generation: currentGeneration,
                forwarders: forwarders
            )
        }
        shutdownTask = cleanup
        await cleanup.value
    }

    private func performShutdown(
        recovery: RecoveryOperation?,
        startup: StartupOperation?,
        generation: Generation?,
        forwarders: [Task<Void, Never>]
    ) async {
        if let recovery { await recovery.task.value }
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
        self.generation = nil
        generationThreadIDs.removeAll()
        activeTurns.removeAll()
        mappedThreadIDs.removeAll()
        setAvailability(.stopped)
        finishStreams()
    }

    var currentAvailability: AgentAvailability { availabilityValue }

    func eventSequenceForTesting(_ threadID: AgentThreadID) -> UInt64 {
        eventSequences[threadID, default: 0]
    }

    var eventSubscriberCountForTesting: Int {
        eventSubscribers.values.reduce(0) { $0 + $1.count }
    }

    private func readyGeneration() async throws -> Generation {
        try Task.checkCancellation()
        guard !stopped else { throw CodexAppServerSupervisorError.stopped }
        guard terminalAvailability == nil else {
            throw CodexAppServerSupervisorError.unavailable
        }
        if let handle = generation {
            if let setup = availabilitySetupTask,
                let initial = await setup.value
            {
                receiveAvailability(initial, generationID: handle.id)
            }
            guard owns(handle) else {
                if stopped { throw CodexAppServerSupervisorError.stopped }
                if let recovery = recoveryOperation {
                    await waitForRecovery(recovery.id)
                    try Task.checkCancellation()
                }
                return try await readyGeneration()
            }
            return handle
        }
        if let recovery = recoveryOperation {
            await waitForRecovery(recovery.id)
            try Task.checkCancellation()
            return try await readyGeneration()
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
            if generation != nil {
                return try await readyGeneration()
            }
            guard startupOperation?.id == operation.id else {
                await client.shutdown()
                throw CodexAppServerSupervisorError.unavailable
            }
            startupOperation = nil
            let installed = installGeneration(client)
            if let setup = availabilitySetupTask,
                let initial = await setup.value
            {
                receiveAvailability(initial, generationID: installed.id)
            }
            guard owns(installed) else {
                if let recovery = recoveryOperation {
                    await waitForRecovery(recovery.id)
                    try Task.checkCancellation()
                }
                return try await readyGeneration()
            }
            return installed
        } catch is CancellationError {
            if startupOperation?.id == operation.id { startupOperation = nil }
            throw CancellationError()
        } catch {
            if startupOperation?.id == operation.id { startupOperation = nil }
            let mapped = availability(for: error)
            if isTerminal(mapped) { terminalAvailability = mapped }
            setAvailability(mapped)
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    private func installGeneration(
        _ client: any CodexAgentClient
    ) -> Generation {
        let installed = Generation(id: UUID(), client: client)
        generation = installed
        generationThreadIDs.removeAll()
        let setup = Task<AgentAvailability?, Never> {
            let stream = await client.availability()
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        availabilitySetupTask = setup
        let streamTask = Task { [weak self, setup] in
            if let initial = await setup.value {
                await self?.receiveAvailability(
                    initial,
                    generationID: installed.id
                )
            }
            let stream = await client.availability()
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
        handle: Generation
    ) async throws {
        guard !generationThreadIDs.contains(threadID) else { return }
        guard mappedThreadIDs.contains(threadID) else {
            throw CodexAppServerSupervisorError.unavailable
        }
        await mappingStore?.insert(threadID)
        guard owns(handle) else {
            throw CodexAppServerSupervisorError.unavailable
        }
        do {
            try await handle.client.resumeThread(threadID)
            guard owns(handle) else {
                throw CodexAppServerSupervisorError.unavailable
            }
            generationThreadIDs.insert(threadID)
            installEventForwarder(threadID: threadID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerSupervisorError.unavailable
        }
    }

    private func owns(_ handle: Generation) -> Bool {
        !stopped && generation?.id == handle.id
    }

    private func compensateLateThread(
        _ threadID: AgentThreadID
    ) async -> LateThreadCompensation {
        pendingCompensationThreadIDs.insert(threadID)
        await mappingStore?.insert(threadID)
        while !stopped, !Task.isCancelled {
            let replacement: Generation
            do {
                replacement = try await readyGeneration()
            } catch {
                break
            }
            do {
                try await replacement.client.ensureThreadDeleted(threadID)
                // Successful exact deletion is terminal even if this
                // generation detached while its response was in flight.
                await mappingStore?.remove(threadID)
                pendingCompensationThreadIDs.remove(threadID)
                return .deleted
            } catch {
                guard !owns(replacement) else { break }
            }
        }
        pendingCompensationThreadIDs.remove(threadID)
        return .transferred
    }

    private func installEventForwarder(threadID: AgentThreadID) {
        guard let generation,
            !pendingCompensationThreadIDs.contains(threadID)
        else { return }
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
            if let turnID = activeTurns[threadID] {
                publish(.turnFailed(turnID, .protocolFailure), for: threadID)
            }
        }
    }

    private func receiveAvailability(
        _ value: AgentAvailability,
        generationID: UUID
    ) {
        guard generation?.id == generationID, !stopped else { return }
        switch value {
        case .crashed:
            generationCrashed(generationID)
        case .unsupportedVersion, .capabilityUnavailable,
            .authenticationRequired, .overloaded:
            generationBecameTerminal(
                generationID,
                availability: sanitized(value)
            )
        case .ready:
            setAvailability(.ready)
        case .starting:
            setAvailability(.starting)
        case .stopped:
            break
        }
    }

    private func generationCrashed(_ generationID: UUID) {
        guard let failed = generation, failed.id == generationID,
            recoveryOperation == nil, !stopped
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
            publish(.turnFailed(turnID, .crashed), for: threadID)
        }
        setAvailability(.crashed)
        let excluded = Set(interrupted.keys)
        let recoveryID = UUID()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.recover(
                id: recoveryID,
                failed: failed,
                interrupted: interrupted,
                forwarders: forwarders,
                excluding: excluded
            )
        }
        recoveryOperation = RecoveryOperation(
            id: recoveryID,
            task: task,
            waiters: [:]
        )
    }

    private func generationBecameTerminal(
        _ generationID: UUID,
        availability: AgentAvailability
    ) {
        guard let failed = generation, failed.id == generationID,
            recoveryOperation == nil, !stopped
        else { return }
        terminalAvailability = availability
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
        let failure = agentFailure(for: availability)
        for (threadID, turnID) in interrupted {
            publish(.turnFailed(turnID, failure), for: threadID)
        }
        setAvailability(availability)
        let operationID = UUID()
        let task = Task<Void, Never> { [weak self] in
            for (threadID, turnID) in interrupted {
                await failed.client.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
            }
            await failed.client.shutdown()
            for forwarder in forwarders { await forwarder.value }
            await self?.clearRecovery(operationID)
        }
        recoveryOperation = RecoveryOperation(
            id: operationID,
            task: task,
            waiters: [:]
        )
    }

    private func recover(
        id: UUID,
        failed: Generation,
        interrupted: [AgentThreadID: AgentTurnID],
        forwarders: [Task<Void, Never>],
        excluding excluded: Set<AgentThreadID>
    ) async {
        for (threadID, turnID) in interrupted {
            await failed.client.interruptTurn(
                threadID: threadID,
                turnID: turnID
            )
        }
        await failed.client.shutdown()
        for forwarder in forwarders { await forwarder.value }
        guard !Task.isCancelled, !stopped else {
            clearRecovery(id)
            return
        }
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
                do {
                    var resumedThreadIDs: [AgentThreadID] = []
                    let resumableThreadIDs = mappedThreadIDs
                        .subtracting(excluded)
                        .subtracting(pendingCompensationThreadIDs)
                    for threadID in resumableThreadIDs {
                        await mappingStore?.insert(threadID)
                        try Task.checkCancellation()
                        try await client.resumeThread(threadID)
                        try Task.checkCancellation()
                        guard !stopped else { throw CancellationError() }
                        resumedThreadIDs.append(threadID)
                    }
                    let initial = await initialAvailability(of: client)
                    guard !Task.isCancelled, !stopped else {
                        throw CancellationError()
                    }
                    switch initial {
                    case .crashed, .stopped, nil:
                        throw CodexAppServerSupervisorStartupError.crashed
                    case .unsupportedVersion:
                        throw CodexAppServerSupervisorStartupError
                            .unsupportedVersion("sanitized")
                    case .authenticationRequired:
                        throw CodexAppServerSupervisorStartupError
                            .authenticationRequired
                    case .capabilityUnavailable:
                        throw CodexAppServerSupervisorStartupError
                            .capabilityUnavailable("sanitized")
                    case .overloaded:
                        throw CodexAppServerSupervisorStartupError.overloaded
                    case .ready, .starting:
                        break
                    }
                    _ = installGeneration(client)
                    generationThreadIDs = Set(resumedThreadIDs)
                    for threadID in resumedThreadIDs {
                        installEventForwarder(threadID: threadID)
                    }
                    setAvailability(initial == .ready ? .ready : .starting)
                    clearRecovery(id)
                    return
                } catch {
                    await client.shutdown()
                    let mapped = availability(for: error)
                    setAvailability(mapped)
                    switch mapped {
                    case .crashed:
                        break
                    default:
                        terminalAvailability = mapped
                        clearRecovery(id)
                        return
                    }
                }
            } catch is CancellationError {
                clearRecovery(id)
                return
            } catch {
                let mapped = availability(for: error)
                setAvailability(mapped)
                switch mapped {
                case .crashed:
                    break
                default:
                    terminalAvailability = mapped
                    clearRecovery(id)
                    return
                }
            }
            attempt += 1
        }
        clearRecovery(id)
    }

    private func initialAvailability(
        of client: any CodexAgentClient
    ) async -> AgentAvailability? {
        let stream = await client.availability()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    private func clearRecovery(_ id: UUID) {
        guard let operation = recoveryOperation, operation.id == id else {
            return
        }
        recoveryOperation = nil
        operation.waiters.values.forEach { $0.resume() }
    }

    private func waitForRecovery(_ operationID: UUID) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: self) { continuation in
                guard !Task.isCancelled,
                    recoveryOperation?.id == operationID
                else {
                    continuation.resume()
                    return
                }
                recoveryOperation?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelRecoveryWaiter(
                    operationID: operationID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelRecoveryWaiter(
        operationID: UUID,
        waiterID: UUID
    ) {
        guard recoveryOperation?.id == operationID else { return }
        recoveryOperation?.waiters.removeValue(forKey: waiterID)?.resume()
    }

    private func detachRecovery() -> RecoveryOperation? {
        guard var operation = recoveryOperation else { return nil }
        recoveryOperation = nil
        let waiters = Array(operation.waiters.values)
        operation.waiters.removeAll()
        waiters.forEach { $0.resume() }
        return operation
    }

    private func availability(for error: any Error) -> AgentAvailability {
        if let initialization = error as? CodexAppServerInitializationError {
            switch initialization {
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

    private func isTerminal(_ availability: AgentAvailability) -> Bool {
        switch availability {
        case .unsupportedVersion, .authenticationRequired,
            .capabilityUnavailable, .overloaded:
            return true
        default:
            return false
        }
    }

    private func sanitized(
        _ availability: AgentAvailability
    ) -> AgentAvailability {
        switch availability {
        case .unsupportedVersion:
            return .unsupportedVersion("Unsupported Codex version")
        case .capabilityUnavailable:
            return .capabilityUnavailable(
                "Required Codex capability unavailable"
            )
        default:
            return availability
        }
    }

    private func agentFailure(
        for availability: AgentAvailability
    ) -> AgentFailure {
        switch availability {
        case .authenticationRequired:
            return .authenticationRequired
        case .overloaded:
            return .overloaded
        case .capabilityUnavailable, .unsupportedVersion:
            return .capabilityUnavailable
        default:
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
        wakeEventSubscribers(for: threadID)
    }

    private func forgetThread(_ threadID: AgentThreadID) {
        mappedThreadIDs.remove(threadID)
        pendingCompensationThreadIDs.remove(threadID)
        generationThreadIDs.remove(threadID)
        activeTurns.removeValue(forKey: threadID)
        eventForwarders.removeValue(forKey: threadID)?.task.cancel()
        eventReplay.removeValue(forKey: threadID)
        eventSequences.removeValue(forKey: threadID)
        finishEvents(for: threadID)
    }

    private func isReplayGap(oldest: UInt64, after cursor: UInt64?) -> Bool {
        guard let cursor else { return oldest > 1 }
        guard cursor < UInt64.max else { return false }
        return oldest > cursor + 1
    }

    private func setAvailability(_ value: AgentAvailability) {
        guard availabilityValue != value else { return }
        availabilityValue = value
        let continuations = availabilityContinuations
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) {
                availabilityContinuations.removeValue(forKey: id)
            }
        }
    }

    private func nextEventDelivery(
        id: UUID,
        waiterID: UUID,
        for threadID: AgentThreadID
    ) async -> AgentEventDelivery? {
        while true {
            guard !Task.isCancelled else {
                cancelEventSubscriber(id, for: threadID)
                return nil
            }
            guard var subscriber = eventSubscribers[threadID]?[id] else {
                return nil
            }
            let replay = eventReplay[threadID] ?? []
            if subscriber.cursor == UInt64.max {
                cancelEventSubscriber(id, for: threadID)
                return nil
            }
            if let oldest = replay.first?.sequence,
                isReplayGap(oldest: oldest, after: subscriber.cursor)
            {
                cancelEventSubscriber(id, for: threadID)
                return .replayGap(
                    after: subscriber.cursor,
                    oldestAvailable: oldest
                )
            }
            if let record = replay.first(where: { record in
                subscriber.cursor.map { record.sequence > $0 } ?? true
            }) {
                subscriber.cursor = record.sequence
                eventSubscribers[threadID]?[id] = subscriber
                return .event(record)
            }
            guard !stopped else {
                cancelEventSubscriber(id, for: threadID)
                return nil
            }
            await waitForEvent(
                id: id,
                waiterID: waiterID,
                threadID: threadID
            )
        }
    }

    private func waitForEvent(
        id: UUID,
        waiterID: UUID,
        threadID: AgentThreadID
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: self) { continuation in
                guard !Task.isCancelled,
                    var subscriber = eventSubscribers[threadID]?[id]
                else {
                    continuation.resume()
                    return
                }
                subscriber.waiters[waiterID] = continuation
                eventSubscribers[threadID]?[id] = subscriber
            }
        } onCancel: {
            Task {
                await self.cancelEventWaiter(
                    id: id,
                    waiterID: waiterID,
                    for: threadID
                )
            }
        }
    }

    private func wakeEventSubscribers(for threadID: AgentThreadID) {
        guard var subscribers = eventSubscribers[threadID] else { return }
        var waiters: [CheckedContinuation<Void, Never>] = []
        for id in subscribers.keys {
            guard var subscriber = subscribers[id] else { continue }
            waiters.append(contentsOf: subscriber.waiters.values)
            subscriber.waiters.removeAll()
            subscribers[id] = subscriber
        }
        eventSubscribers[threadID] = subscribers
        waiters.forEach { $0.resume() }
    }

    private func cancelEventSubscriber(
        _ id: UUID,
        for threadID: AgentThreadID
    ) {
        let waiters = eventSubscribers[threadID]?
            .removeValue(forKey: id)?.waiters.values ?? [:].values
        if eventSubscribers[threadID]?.isEmpty == true {
            eventSubscribers.removeValue(forKey: threadID)
        }
        waiters.forEach { $0.resume() }
    }

    private func cancelEventWaiter(
        id: UUID,
        waiterID: UUID,
        for threadID: AgentThreadID
    ) {
        eventSubscribers[threadID]?[id]?
            .waiters.removeValue(forKey: waiterID)?.resume()
    }

    private func finishEvents(for threadID: AgentThreadID) {
        let subscribers = eventSubscribers.removeValue(forKey: threadID) ?? [:]
        subscribers.values.flatMap { $0.waiters.values }.forEach { $0.resume() }
    }

    private func removeAvailabilityContinuation(_ id: UUID) {
        availabilityContinuations.removeValue(forKey: id)
    }

    private func finishStreams() {
        let subscribers = eventSubscribers
        eventSubscribers.removeAll()
        subscribers.values.flatMap(\.values).flatMap { $0.waiters.values }
            .forEach { $0.resume() }
        availabilityContinuations.values.forEach { $0.finish() }
        availabilityContinuations.removeAll()
    }
}
