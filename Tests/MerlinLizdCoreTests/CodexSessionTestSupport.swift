import Foundation
@testable import MerlinLizdCore

actor CodexSessionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

actor CodexSessionCallProbe {
    private var counts: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ name: String) {
        counts[name, default: 0] += 1
        let ready = waiters.removeValue(forKey: name) ?? []
        ready.forEach { $0.resume() }
    }

    func wait(for name: String) async {
        if counts[name, default: 0] > 0 { return }
        await withCheckedContinuation { waiters[name, default: []].append($0) }
    }

    func count(_ name: String) -> Int {
        counts[name, default: 0]
    }
}

enum CodexSessionTestDeadlineError: Error {
    case timedOut
}

enum CodexSessionStoreFailure: Error {
    case injected
}

final class CodexSynchronousFailureScript: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var callCount = 0

    init(failures: Int) {
        remainingFailures = failures
    }

    func call() throws {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw CodexConversationStoreError.posixFailure(
                operation: "fsync",
                path: "CodexConversations",
                code: 5
            )
        }
    }

    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

enum CodexSessionStoreMutationKind: Hashable, Sendable {
    case insertIfAbsent
    case recordOrphan
    case advanceDeletion(CodexDeletionStage)
    case advanceArchive(CodexArchiveReconciliationStage)
    case completeArchive
}

actor FaultInjectingCodexConversationStore: CodexConversationStoring {
    private let base: any CodexConversationStoring
    private var remainingFailures: [CodexSessionStoreMutationKind: Int]

    init(
        base: any CodexConversationStoring,
        failures: [CodexSessionStoreMutationKind: Int]
    ) {
        self.base = base
        remainingFailures = failures
    }

    func snapshot() async throws -> CodexConversationStoreSnapshot {
        try await base.snapshot()
    }

    func recoverDurableSnapshot() async throws -> CodexConversationStoreSnapshot {
        try await base.recoverDurableSnapshot()
    }

    func apply(
        _ mutation: CodexConversationStoreMutation
    ) async throws -> CodexConversationStoreSnapshot {
        if let kind = kind(of: mutation),
            remainingFailures[kind, default: 0] > 0
        {
            remainingFailures[kind, default: 0] -= 1
            throw CodexConversationStoreError.posixFailure(
                operation: "injected",
                path: "conversation-store",
                code: 5
            )
        }
        return try await base.apply(mutation)
    }

    private func kind(
        of mutation: CodexConversationStoreMutation
    ) -> CodexSessionStoreMutationKind? {
        switch mutation {
        case .insertIfAbsent:
            .insertIfAbsent
        case .recordOrphan:
            .recordOrphan
        case let .advanceDeletion(_, stage, _):
            .advanceDeletion(stage)
        case let .advanceArchiveChange(_, stage, _):
            .advanceArchive(stage)
        case .completeArchiveChange:
            .completeArchive
        default:
            nil
        }
    }
}

actor IndeterminateRereadCodexConversationStore: CodexConversationStoring {
    private let base: any CodexConversationStoring
    private var didPersist = false

    init(base: any CodexConversationStoring) {
        self.base = base
    }

    func snapshot() async throws -> CodexConversationStoreSnapshot {
        guard !didPersist else { throw CodexSessionStoreFailure.injected }
        return try await base.snapshot()
    }

    func recoverDurableSnapshot() async throws -> CodexConversationStoreSnapshot {
        guard !didPersist else { throw CodexSessionStoreFailure.injected }
        return try await base.recoverDurableSnapshot()
    }

    func apply(
        _ mutation: CodexConversationStoreMutation
    ) async throws -> CodexConversationStoreSnapshot {
        _ = try await base.apply(mutation)
        didPersist = true
        throw CodexConversationStoreError.posixFailure(
            operation: "fsync",
            path: "CodexConversations",
            code: 5
        )
    }
}

actor TransientIndeterminateCodexConversationStore: CodexConversationStoring {
    private let base: any CodexConversationStoring
    private let persistFirstInsert: Bool
    private var didFailInsert = false
    private var shouldFailRecovery = false

    init(
        base: any CodexConversationStoring,
        persistFirstInsert: Bool
    ) {
        self.base = base
        self.persistFirstInsert = persistFirstInsert
    }

    func snapshot() async throws -> CodexConversationStoreSnapshot {
        try await base.snapshot()
    }

    func recoverDurableSnapshot() async throws -> CodexConversationStoreSnapshot {
        if shouldFailRecovery {
            shouldFailRecovery = false
            throw CodexSessionStoreFailure.injected
        }
        return try await base.recoverDurableSnapshot()
    }

    func apply(
        _ mutation: CodexConversationStoreMutation
    ) async throws -> CodexConversationStoreSnapshot {
        guard !didFailInsert, case .insertIfAbsent = mutation else {
            return try await base.apply(mutation)
        }
        didFailInsert = true
        if persistFirstInsert {
            _ = try await base.apply(mutation)
        }
        shouldFailRecovery = true
        throw CodexConversationStoreError.posixFailure(
            operation: "injected-pre-rename",
            path: "conversation-store",
            code: 5
        )
    }
}

private actor CodexSessionTestRace<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Result<Value, any Error>, Never>]
        = []

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume(returning: result) }
    }

    func wait() async -> Result<Value, any Error> {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

func codexSessionWithDeadline<Value: Sendable>(
    timeout: Duration = .seconds(3),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = CodexSessionTestRace<Value>()
    let operationTask = Task {
        do {
            await race.resolve(.success(try await operation()))
        } catch {
            await race.resolve(.failure(error))
        }
    }
    let deadlineTask = Task {
        do {
            try await Task.sleep(for: timeout)
            await race.resolve(.failure(CodexSessionTestDeadlineError.timedOut))
        } catch {}
    }
    let result = await race.wait()
    operationTask.cancel()
    deadlineTask.cancel()
    await deadlineTask.value
    return try result.get()
}

actor FakeCodexSessionAgent: CodexAgentClient {
    enum Failure: Error, Equatable {
        case archive
        case delete
        case resume
        case start
        case steer
    }

    struct SteerCall: Equatable, Sendable {
        let threadID: AgentThreadID
        let turnID: AgentTurnID
        let prompt: String
    }

    struct InterruptCall: Equatable, Sendable {
        let threadID: AgentThreadID
        let turnID: AgentTurnID
    }

    private let probe = CodexSessionCallProbe()
    private var nextThreadIDs: [AgentThreadID]
    private var nextTurnIDs: [AgentThreadID: [AgentTurnID]] = [:]
    private var startThreadGate: CodexSessionTestGate?
    private var archiveGate: CodexSessionTestGate?
    private var deleteGate: CodexSessionTestGate?
    private var interruptGate: CodexSessionTestGate?
    private var startTurnGates: [AgentThreadID: CodexSessionTestGate] = [:]
    private var resumeGates: [AgentThreadID: CodexSessionTestGate] = [:]
    private var resumeEvents: [AgentThreadID: [AgentEvent]] = [:]
    private var streams: [
        AgentThreadID: AsyncStream<AgentEventDelivery>.Continuation
    ] = [:]
    private var streamValues: [
        AgentThreadID: AsyncStream<AgentEventDelivery>
    ] = [:]
    private var nextEventSequences: [AgentThreadID: UInt64] = [:]
    private var replacementReplays: [AgentThreadID: [AgentEventRecord]] = [:]
    private var eventCursors: [AgentThreadID: [UInt64?]] = [:]
    private var resumeCalls: [AgentThreadID] = []
    private var startCalls: [(AgentThreadID, String)] = []
    private var steerCalls: [SteerCall] = []
    private var interruptCalls: [InterruptCall] = []
    private var archiveCalls: [AgentThreadID] = []
    private var unarchiveCalls: [AgentThreadID] = []
    private var deleteCalls: [AgentThreadID] = []
    private var deletedThreads: Set<AgentThreadID> = []
    private var failure: Failure?

    init(threadIDs: [AgentThreadID]) {
        nextThreadIDs = threadIDs
    }

    func startThread() async throws -> AgentThreadID {
        await probe.record("startThread")
        if let startThreadGate { await startThreadGate.wait() }
        if failure == .start { throw Failure.start }
        return nextThreadIDs.removeFirst()
    }

    func resumeThread(_ threadID: AgentThreadID) async throws {
        await probe.record("resume:\(threadID.rawValue)")
        if failure == .resume { throw Failure.resume }
        resumeCalls.append(threadID)
        for event in resumeEvents[threadID, default: []] {
            publish(event, for: threadID)
        }
        if let gate = resumeGates[threadID] {
            await gate.wait()
        }
    }

    func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) async throws -> AgentTurnID {
        startCalls.append((threadID, prompt))
        await probe.record("startTurn:\(threadID.rawValue)")
        if let gate = startTurnGates[threadID] {
            await gate.wait()
        }
        if failure == .start { throw Failure.start }
        return nextTurnIDs[threadID, default: []].removeFirst()
    }

    func steerTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        prompt: String
    ) async throws {
        steerCalls.append(
            SteerCall(threadID: threadID, turnID: turnID, prompt: prompt)
        )
        await probe.record("steer:\(threadID.rawValue)")
        if failure == .steer { throw Failure.steer }
    }

    func interruptTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async {
        interruptCalls.append(
            InterruptCall(threadID: threadID, turnID: turnID)
        )
        await probe.record("interrupt:\(threadID.rawValue)")
        if let interruptGate { await interruptGate.wait() }
    }

    func events(
        for threadID: AgentThreadID,
        after sequence: UInt64?
    ) async -> AsyncStream<AgentEventDelivery> {
        eventCursors[threadID, default: []].append(sequence)
        if let stream = streamValues[threadID] { return stream }
        let pair = AsyncStream<AgentEventDelivery>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        streams[threadID] = pair.continuation
        streamValues[threadID] = pair.stream
        for record in replacementReplays.removeValue(forKey: threadID) ?? [] {
            _ = pair.continuation.yield(.event(record))
            nextEventSequences[threadID] = max(
                nextEventSequences[threadID, default: 0],
                record.sequence
            )
        }
        await probe.record("events:\(threadID.rawValue)")
        return pair.stream
    }

    func availability() async -> AsyncStream<AgentAvailability> {
        AsyncStream { $0.finish() }
    }

    func archiveThread(_ threadID: AgentThreadID) async throws {
        archiveCalls.append(threadID)
        await probe.record("archive:\(threadID.rawValue)")
        if let archiveGate { await archiveGate.wait() }
        if failure == .archive { throw Failure.archive }
    }

    func unarchiveThread(_ threadID: AgentThreadID) async throws {
        unarchiveCalls.append(threadID)
        if failure == .archive { throw Failure.archive }
    }

    func deleteThread(_ threadID: AgentThreadID) async throws {
        deleteCalls.append(threadID)
        await probe.record("delete:\(threadID.rawValue)")
        if let deleteGate { await deleteGate.wait() }
        if failure == .delete { throw Failure.delete }
        deletedThreads.insert(threadID)
    }

    func ensureThreadDeleted(_ threadID: AgentThreadID) async throws {
        if deletedThreads.contains(threadID) { return }
        try await deleteThread(threadID)
    }

    func shutdown() async {
        await probe.record("shutdown")
    }

    func enqueueTurn(_ turnID: AgentTurnID, for threadID: AgentThreadID) {
        nextTurnIDs[threadID, default: []].append(turnID)
    }

    func blockStartThread(on gate: CodexSessionTestGate?) {
        startThreadGate = gate
    }

    func blockArchive(on gate: CodexSessionTestGate?) {
        archiveGate = gate
    }

    func blockDelete(on gate: CodexSessionTestGate?) {
        deleteGate = gate
    }

    func blockInterrupt(on gate: CodexSessionTestGate?) {
        interruptGate = gate
    }

    func blockStartTurn(
        for threadID: AgentThreadID,
        on gate: CodexSessionTestGate?
    ) {
        startTurnGates[threadID] = gate
    }

    func emitWhileResuming(
        _ events: [AgentEvent],
        threadID: AgentThreadID,
        gate: CodexSessionTestGate
    ) {
        resumeEvents[threadID] = events
        resumeGates[threadID] = gate
    }

    func emit(_ event: AgentEvent, for threadID: AgentThreadID) {
        publish(event, for: threadID)
    }

    func emitSequenced(_ record: AgentEventRecord, for threadID: AgentThreadID) {
        nextEventSequences[threadID] = max(
            nextEventSequences[threadID, default: 0],
            record.sequence
        )
        _ = streams[threadID]?.yield(.event(record))
    }

    func emitReplayGap(
        after sequence: UInt64?,
        oldestAvailable: UInt64,
        for threadID: AgentThreadID
    ) {
        _ = streams[threadID]?.yield(.replayGap(
            after: sequence,
            oldestAvailable: oldestAvailable
        ))
    }

    func setReplacementReplay(
        _ records: [AgentEventRecord],
        for threadID: AgentThreadID
    ) {
        replacementReplays[threadID] = records
    }

    func recordedEventCursors(for threadID: AgentThreadID) -> [UInt64?] {
        eventCursors[threadID, default: []]
    }

    private func publish(_ event: AgentEvent, for threadID: AgentThreadID) {
        let sequence = nextEventSequences[threadID, default: 0] &+ 1
        nextEventSequences[threadID] = sequence
        _ = streams[threadID]?.yield(.event(.init(
            sequence: sequence,
            event: event
        )))
    }

    func finishEvents(for threadID: AgentThreadID) {
        streams.removeValue(forKey: threadID)?.finish()
        streamValues.removeValue(forKey: threadID)
    }

    func waitForCall(_ name: String) async {
        await probe.wait(for: name)
    }

    func recordedCallCount(_ name: String) async -> Int {
        await probe.count(name)
    }

    func recordedStartCalls() -> [(AgentThreadID, String)] {
        startCalls
    }

    func recordedSteerCalls() -> [SteerCall] {
        steerCalls
    }

    func recordedInterruptCalls() -> [InterruptCall] {
        interruptCalls
    }

    func recordedResumeCalls() -> [AgentThreadID] { resumeCalls }
    func recordedArchiveCalls() -> [AgentThreadID] { archiveCalls }
    func recordedUnarchiveCalls() -> [AgentThreadID] { unarchiveCalls }
    func recordedDeleteCalls() -> [AgentThreadID] { deleteCalls }

    func setFailure(_ failure: Failure?) {
        self.failure = failure
    }
}

actor CodexSessionJournalSpy: TerminalOperationJournaling {
    enum Failure: Error { case delete }

    private var events: [TerminalJournalEvent] = []
    private var deletedKeys: [TerminalConversationKey] = []
    private var failDelete = false

    func append(_ event: TerminalJournalEvent) async throws {
        events.append(event)
    }

    func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent] {
        events.filter { $0.key == key }
    }

    func recentEntries(
        for key: TerminalConversationKey,
        request: TerminalJournalReadPageRequest
    ) async throws -> TerminalJournalReadPage {
        terminalInMemoryRecentPage(
            events.filter { $0.key == key },
            request: request
        )
    }

    func deleteJournal(for key: TerminalConversationKey) async throws {
        if failDelete { throw Failure.delete }
        deletedKeys.append(key)
        events.removeAll { $0.key == key }
    }

    func setFailDelete(_ value: Bool) { failDelete = value }
    func deletions() -> [TerminalConversationKey] { deletedKeys }
}

actor CodexSessionStateProbe {
    private struct Waiter {
        let id: UUID
        let key: TerminalConversationKey
        let phase: CodexSessionPhase
        let messageText: String?
        let continuation: CheckedContinuation<CodexSessionState, Never>
    }

    private var latest: [TerminalConversationKey: CodexSessionState] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var consumer: Task<Void, Never>?

    func start(
        _ stream: AsyncStream<[
            TerminalConversationKey: CodexSessionState
        ]>
    ) {
        consumer = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(snapshot)
            }
        }
    }

    func wait(
        for key: TerminalConversationKey,
        phase: CodexSessionPhase,
        containingMessage messageText: String? = nil
    ) async -> CodexSessionState {
        if let state = latest[key],
            matches(state, phase: phase, messageText: messageText)
        {
            return state
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let state = latest[key],
                    matches(state, phase: phase, messageText: messageText)
                {
                    continuation.resume(returning: state)
                    return
                }
                waiters[id] = Waiter(
                    id: id,
                    key: key,
                    phase: phase,
                    messageText: messageText,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
    }

    private func receive(
        _ snapshot: [TerminalConversationKey: CodexSessionState]
    ) {
        latest = snapshot
        let ready = waiters.values.filter {
            guard let state = snapshot[$0.key] else { return false }
            return matches(
                state,
                phase: $0.phase,
                messageText: $0.messageText
            )
        }
        for waiter in ready {
            waiters.removeValue(forKey: waiter.id)
            waiter.continuation.resume(returning: snapshot[waiter.key]!)
        }
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(
            returning: latest[waiter.key]
                ?? CodexSessionState(key: waiter.key)
        )
    }

    private func matches(
        _ state: CodexSessionState,
        phase: CodexSessionPhase,
        messageText: String?
    ) -> Bool {
        guard state.phase == phase else { return false }
        guard let messageText else { return true }
        return state.messages.contains { $0.text == messageText }
    }
}

struct CodexSessionPersistenceFixture: Sendable {
    let applicationSupportDirectory: URL

    init() throws {
        applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "merlin-lizd-codex-sessions-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: applicationSupportDirectory)
    }
}

func codexTestKey(
    serverSessionID: String = "$31",
    createdAtEpoch: Int64 = 1_721_000_000
) -> TerminalConversationKey {
    TerminalConversationKey(
        target: .devbox(sid: "devbox-31"),
        tmux: TmuxSessionIdentity(
            serverSessionID: serverSessionID,
            createdAtEpoch: createdAtEpoch
        )
    )
}

func codexTestRecord(
    key: TerminalConversationKey = codexTestKey(),
    threadID: String = "thread-31",
    archived: Bool = false,
    updatedAt: Date = Date(timeIntervalSince1970: 1_721_000_100)
) -> CodexConversationRecord {
    CodexConversationRecord(
        key: key,
        threadID: AgentThreadID(rawValue: threadID),
        protocolGeneration: CodexConversationRecord.currentProtocolGeneration,
        archived: archived,
        updatedAt: updatedAt
    )
}

func codexTestEndpoint(
    key: TerminalConversationKey,
    id: UUID = UUID(),
    port: FakeTerminalToolPort
) -> TerminalEndpoint {
    let target: TerminalTarget
    switch key.target {
    case .local:
        target = .local
    case let .devbox(sid):
        target = .devbox(sid: sid, name: "test", alias: "test")
    case let .worker(devboxSID, workerID):
        target = .worker(
            devboxSID: devboxSID,
            devboxName: "test",
            alias: "test",
            workerID: workerID
        )
    }
    let surface = TmuxSurface(
        sessionIdentity: key.tmux,
        windowID: "@1",
        paneID: "%1",
        currentCommand: "zsh"
    )
    return TerminalEndpoint(
        id: TerminalEndpointID(rawValue: id),
        conversationKey: key,
        terminal: port,
        surfaces: FakeTerminalSurfaceController(surface: surface),
        route: TmuxRoute(
            target: target,
            sessionName: "test",
            expectedIdentity: key.tmux
        )
    )
}

func codexPOSIXMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.posixPermissions] as? Int ?? -1
}

func codexWrite(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
}

extension CodexDeletionStage {
    static let allCasesForTesting: [CodexDeletionStage] = [
        .intentPersisted,
        .remoteThreadDeleted,
        .journalDeleted,
        .routerForgotten,
    ]
}
