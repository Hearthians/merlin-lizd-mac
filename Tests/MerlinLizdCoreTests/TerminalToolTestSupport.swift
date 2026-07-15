import Foundation
@testable import MerlinLizdCore

func terminalApprovalDecodeRejectsOversizedSurface(
    _ scope: TerminalApprovalScope
) throws -> Bool {
    try terminalApprovalMutatedDecodeFails(scope) { context in
        guard var surface = context["surface"] as? [String: Any] else {
            return false
        }
        surface["currentCommand"] = String(
            repeating: "x",
            count: TerminalApprovalSurfaceContext
                .maximumCurrentCommandByteCount + 1
        )
        context["surface"] = surface
        return true
    }
}

func terminalApprovalDecodeRejectsOversizedScreen(
    _ scope: TerminalApprovalScope
) throws -> Bool {
    try terminalApprovalMutatedDecodeFails(scope) { context in
        guard var screen = context["screen"] as? [String: Any] else {
            return false
        }
        screen["text"] = String(
            repeating: "界",
            count: TerminalApprovalScreenContext.maximumTextByteCount
        )
        context["screen"] = screen
        return true
    }
}

private func terminalApprovalMutatedDecodeFails(
    _ scope: TerminalApprovalScope,
    mutate: (inout [String: Any]) -> Bool
) throws -> Bool {
    let encoded = try JSONEncoder().encode(scope)
    guard var root = try JSONSerialization.jsonObject(with: encoded)
        as? [String: Any],
        var context = root["context"] as? [String: Any],
        mutate(&context)
    else { return false }
    root["context"] = context
    let data = try JSONSerialization.data(withJSONObject: root)
    do {
        _ = try JSONDecoder().decode(TerminalApprovalScope.self, from: data)
        return false
    } catch is DecodingError {
        return true
    } catch {
        return false
    }
}

actor TerminalToolTestGate {
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

actor TerminalBindingValidationGate {
    private let blockedCall: Int
    private let gate: TerminalToolTestGate
    private var calls = 0

    init(blockedCall: Int, gate: TerminalToolTestGate) {
        self.blockedCall = blockedCall
        self.gate = gate
    }

    func validate() async {
        calls += 1
        if calls == blockedCall {
            await gate.wait()
        }
    }

    func count() -> Int { calls }
}

actor TerminalToolTestLog {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

actor TerminalToolCompletionProbe {
    private var error: TerminalToolRouterError?
    private var didComplete = false

    func complete(with error: TerminalToolRouterError?) {
        self.error = error
        didComplete = true
    }

    func snapshot() -> (didComplete: Bool, error: TerminalToolRouterError?) {
        (didComplete, error)
    }
}

actor TerminalRegistryCompletionProbe {
    private var error: TerminalEndpointRegistryError?
    private var didComplete = false

    func complete(with error: TerminalEndpointRegistryError?) {
        self.error = error
        didComplete = true
    }

    func snapshot() -> (
        didComplete: Bool,
        error: TerminalEndpointRegistryError?
    ) {
        (didComplete, error)
    }
}

actor TerminalTerminationCompletionProbe {
    private var error: TerminalTurnTerminationError?
    private var didComplete = false

    func complete(with error: TerminalTurnTerminationError?) {
        self.error = error
        didComplete = true
    }

    func snapshot() -> (
        didComplete: Bool,
        error: TerminalTurnTerminationError?
    ) {
        (didComplete, error)
    }
}

actor FakeTerminalToolPort: TerminalSessionPort {
    enum Failure: Error, Equatable {
        case send
        case observe
        case wait
    }

    private var snapshot: TerminalScreenSnapshot
    private var waitResults: [TerminalScreenWaitResult] = []
    private var observeFailures: [Failure?] = []
    private var waitFailures: [Failure?] = []
    private var sendFailures: [Failure?] = []
    private var sentBatches: [TerminalInputBatch] = []
    private var owners: [TerminalKeyboardOwner] = []
    private var ownerTransitionsStarted: [TerminalKeyboardOwner] = []
    private var ownerTransitionWaiters: [
        TerminalKeyboardOwner: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var ownerGates: [TerminalKeyboardOwner: TerminalToolTestGate] = [:]
    private var observeCount = 0
    private var waitCount = 0
    private var sendCount = 0
    private var observeGate: TerminalToolTestGate?
    private var checkCancellationAfterObserveGate = false
    private var sendGate: TerminalToolTestGate?
    private var waitGate: TerminalToolTestGate?
    private var checkCancellationAfterWaitGate = false
    private let label: String
    private let log: TerminalToolTestLog?

    init(
        snapshot: TerminalScreenSnapshot,
        label: String = "port",
        log: TerminalToolTestLog? = nil
    ) {
        self.snapshot = snapshot
        self.label = label
        self.log = log
    }

    func observeScreen() async throws -> TerminalScreenSnapshot {
        observeCount += 1
        await log?.append("\(label):observe")
        if let observeGate {
            await observeGate.wait()
            if checkCancellationAfterObserveGate {
                try Task.checkCancellation()
            }
        }
        if !observeFailures.isEmpty,
            let failure = observeFailures.removeFirst()
        {
            throw failure
        }
        return snapshot
    }

    func sendInput(_ batch: TerminalInputBatch) async throws -> TerminalInputReceipt {
        sendCount += 1
        sentBatches.append(batch)
        await log?.append("\(label):send:\(batch.purpose)")
        if !sendFailures.isEmpty, let failure = sendFailures.removeFirst() {
            throw failure
        }
        if let sendGate {
            await sendGate.wait()
        }
        return TerminalInputReceipt(
            acceptedRevision: batch.expectedRevision,
            byteCount: batch.events.count
        )
    }

    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        waitCount += 1
        await log?.append("\(label):wait")
        if !waitFailures.isEmpty, let failure = waitFailures.removeFirst() {
            throw failure
        }
        if let waitGate {
            await waitGate.wait()
            if checkCancellationAfterWaitGate {
                try Task.checkCancellation()
            }
        }
        guard !waitResults.isEmpty else {
            return TerminalScreenWaitResult(snapshot: snapshot, timedOut: false)
        }
        let result = waitResults.removeFirst()
        snapshot = result.snapshot
        return result
    }

    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) async {
        ownerTransitionsStarted.append(owner)
        let waiters = ownerTransitionWaiters.removeValue(forKey: owner) ?? []
        waiters.forEach { $0.resume() }
        await log?.append("\(label):owner-start:\(owner)")
        if let gate = ownerGates[owner] {
            await gate.wait()
        }
        owners.append(owner)
        await log?.append("\(label):owner:\(owner)")
    }

    func setSnapshot(_ snapshot: TerminalScreenSnapshot) {
        self.snapshot = snapshot
    }

    func enqueueWait(_ result: TerminalScreenWaitResult) {
        waitResults.append(result)
    }

    func enqueueObserveFailure(_ failure: Failure?) {
        observeFailures.append(failure)
    }

    func enqueueWaitFailure(_ failure: Failure?) {
        waitFailures.append(failure)
    }

    func enqueueSendFailure(_ failure: Failure?) {
        sendFailures.append(failure)
    }

    func blockObserves(
        on gate: TerminalToolTestGate?,
        checkCancellationAfterGate: Bool = false
    ) {
        observeGate = gate
        checkCancellationAfterObserveGate = checkCancellationAfterGate
    }

    func blockSends(on gate: TerminalToolTestGate?) {
        sendGate = gate
    }

    func blockWaits(
        on gate: TerminalToolTestGate?,
        checkCancellationAfterGate: Bool = false
    ) {
        waitGate = gate
        checkCancellationAfterWaitGate = checkCancellationAfterGate
    }

    func blockKeyboardOwner(
        _ owner: TerminalKeyboardOwner,
        on gate: TerminalToolTestGate?
    ) {
        ownerGates[owner] = gate
    }

    func counts() -> (observe: Int, send: Int, wait: Int) {
        (observeCount, sendCount, waitCount)
    }

    func batches() -> [TerminalInputBatch] {
        sentBatches
    }

    func keyboardOwners() -> [TerminalKeyboardOwner] {
        owners
    }

    func keyboardOwnerTransitionsStarted() -> [TerminalKeyboardOwner] {
        ownerTransitionsStarted
    }

    func waitForKeyboardOwnerStart(_ owner: TerminalKeyboardOwner) async {
        if ownerTransitionsStarted.contains(owner) { return }
        await withCheckedContinuation {
            ownerTransitionWaiters[owner, default: []].append($0)
        }
    }
}

actor FakeTerminalSurfaceController: TmuxSurfaceControlling {
    enum Failure: Error, Equatable {
        case current
        case currentCancelled
        case select
        case create
        case close
    }

    private var surface: TmuxSurface
    private var createdSurface: TmuxSurface
    private var failure: Failure?
    private var retainedCreateError: (
        pane: RetainedTemporaryPane,
        reason: RetainedTemporaryPaneReason
    )?
    private var currentGate: TerminalToolTestGate?
    private var checkCancellationAfterCurrentGate = false
    private var closeGate: TerminalToolTestGate?
    private var checkCancellationAfterCloseGate = false
    private var closeOutcome: TmuxTemporaryPaneCloseOutcome = .closed(
        restoration: .restored
    )
    private var calls: [String] = []
    private let log: TerminalToolTestLog?

    init(
        surface: TmuxSurface,
        createdSurface: TmuxSurface? = nil,
        log: TerminalToolTestLog? = nil
    ) {
        self.surface = surface
        self.createdSurface = createdSurface ?? surface
        self.log = log
    }

    func currentSurface(route: TmuxRoute) async throws -> TmuxSurface {
        calls.append("current")
        await log?.append("surface:current")
        if let currentGate {
            await currentGate.wait()
            if checkCancellationAfterCurrentGate {
                try Task.checkCancellation()
            }
        }
        if failure == .currentCancelled { throw CancellationError() }
        if failure == .current { throw Failure.current }
        return surface
    }

    func select(
        _ selection: TmuxVisibleSelection,
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
        calls.append("select")
        await log?.append("surface:select")
        if failure == .select { throw Failure.select }
        surface = createdSurface
        return surface
    }

    func createTemporaryPane(
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
        calls.append("create")
        await log?.append("surface:create")
        if let retainedCreateError {
            throw TmuxSurfaceControlError.temporaryPaneRetained(
                pane: retainedCreateError.pane,
                reason: retainedCreateError.reason
            )
        }
        if failure == .create { throw Failure.create }
        surface = createdSurface
        return surface
    }

    func closeTemporaryPane(
        _ paneID: String,
        restoring origin: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxTemporaryPaneCloseOutcome {
        calls.append("close:\(paneID)")
        await log?.append("surface:close")
        if let closeGate {
            await closeGate.wait()
            if checkCancellationAfterCloseGate {
                try Task.checkCancellation()
            }
        }
        if failure == .close { throw Failure.close }
        if closeOutcome == .closed(restoration: .restored) {
            surface = origin
        }
        return closeOutcome
    }

    func setSurface(_ surface: TmuxSurface) {
        self.surface = surface
    }

    func setCreatedSurface(_ surface: TmuxSurface) {
        createdSurface = surface
    }

    func setFailure(_ failure: Failure?) {
        self.failure = failure
    }

    func blockCurrentSurface(
        on gate: TerminalToolTestGate?,
        checkCancellationAfterGate: Bool = false
    ) {
        currentGate = gate
        checkCancellationAfterCurrentGate = checkCancellationAfterGate
    }

    func blockClose(
        on gate: TerminalToolTestGate?,
        checkCancellationAfterGate: Bool = false
    ) {
        closeGate = gate
        checkCancellationAfterCloseGate = checkCancellationAfterGate
    }

    func setCloseOutcome(_ outcome: TmuxTemporaryPaneCloseOutcome) {
        closeOutcome = outcome
    }

    func setRetainedCreateError(
        pane: RetainedTemporaryPane,
        reason: RetainedTemporaryPaneReason
    ) {
        retainedCreateError = (pane, reason)
    }

    func recordedCalls() -> [String] {
        calls
    }
}

actor MemoryTerminalToolJournal: TerminalOperationJournaling {
    enum Failure: Error {
        case append
    }

    private var events: [TerminalJournalEvent] = []
    private var failAppend = false
    private var failOnAppendNumber: Int?
    private var appendCount = 0
    private let log: TerminalToolTestLog?

    init(log: TerminalToolTestLog? = nil) {
        self.log = log
    }

    func append(_ event: TerminalJournalEvent) async throws {
        appendCount += 1
        if failAppend || appendCount == failOnAppendNumber {
            throw Failure.append
        }
        events.append(event)
        await log?.append("journal:\(event.kind.testName)")
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
        events.removeAll { $0.key == key }
    }

    func setFailAppend(_ value: Bool) {
        failAppend = value
    }

    func failOnAppend(_ number: Int?) {
        failOnAppendNumber = number
    }

    func failAfterAdditionalAppends(_ count: Int) {
        failOnAppendNumber = appendCount + count
    }

    func snapshot() -> [TerminalJournalEvent] {
        events
    }
}

private extension TerminalJournalEventKind {
    var testName: String {
        switch self {
        case .request: "request"
        case .screen: "screen"
        case .risk: "risk"
        case .approval: "approval"
        case .endpoint: "endpoint"
        case .emittedBatch: "batch"
        case .result: "result"
        case .temporaryPane: "temporary"
        }
    }
}

enum TerminalToolFixtures {
    static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    static func newID() -> UUID {
        UUID()
    }

    static let identity = TmuxSessionIdentity(
        serverSessionID: "$7",
        createdAtEpoch: 1_784_000_102
    )

    static let key = TerminalConversationKey(
        target: .local,
        tmux: identity
    )

    static let route = TmuxRoute(
        target: .local,
        sessionName: "training",
        expectedIdentity: identity
    )

    static func screen(
        revision: UInt64,
        text: String = "$ ",
        columns: Int = 120,
        cursorColumn: Int = 2
    ) -> TerminalScreenSnapshot {
        TerminalScreenSnapshot(
            revision: revision,
            columns: columns,
            rows: 24,
            cursor: TerminalCursor(
                row: 0,
                column: cursorColumn,
                isVisible: true
            ),
            mode: .normal,
            text: text,
            significantRuns: [],
            changedRows: [0]
        )
    }

    static func surface(
        paneID: String = "%1",
        command: String = "zsh"
    ) -> TmuxSurface {
        TmuxSurface(
            sessionIdentity: identity,
            windowID: "@1",
            paneID: paneID,
            currentCommand: command
        )
    }

    static func endpoint(
        id: UUID,
        key: TerminalConversationKey = key,
        port: any TerminalSessionPort,
        controller: any TmuxSurfaceControlling,
        route: TmuxRoute = route
    ) -> TerminalEndpoint {
        TerminalEndpoint(
            id: TerminalEndpointID(rawValue: id),
            conversationKey: key,
            terminal: port,
            surfaces: controller,
            route: route
        )
    }

    static func input(
        revision: UInt64,
        text: String = "pwd",
        purpose: String = "type command",
        risk: TerminalRisk = .routine
    ) -> TerminalInputBatch {
        TerminalInputBatch(
            expectedRevision: revision,
            events: [.text(text)],
            purpose: purpose,
            declaredRisk: risk
        )
    }
}
