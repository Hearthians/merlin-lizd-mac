import Combine
import Foundation
import MerlinLizdCodexAdapter
import MerlinLizdCore

struct CodexOperationRecord: Identifiable, Equatable {
    let id: UUID
    let events: [TerminalJournalEvent]

    var title: String {
        for event in events {
            if case let .request(operation, purpose) = event.kind {
                let boundedOperation = String(operation.prefix(80))
                let boundedPurpose = String(purpose.prefix(160))
                return boundedPurpose.isEmpty
                    ? boundedOperation
                    : "\(boundedOperation) · \(boundedPurpose)"
            }
        }
        return "Terminal operation"
    }

    var timestamp: Date? { events.last?.timestamp }
}

@MainActor
final class CodexDrawerModel: ObservableObject {
    @Published private(set) var state: CodexDrawerState
    @Published private(set) var operations: [CodexOperationRecord] = []
    @Published private(set) var journalNotice: String?
    @Published private(set) var journalHistoryNotice: String?

    private let coordinator: CodexSessionCoordinator?
    private let supervisor: CodexAppServerSupervisor?
    private let journal: (any TerminalOperationJournalReading)?
    private var stateTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var journalTask: Task<Void, Never>?
    private var terminalSelectionObserver: AnyCancellable?

    init(runtime: CodexRuntime?, terminals: TerminalTabsModel) {
        coordinator = runtime?.coordinator
        supervisor = runtime?.supervisor
        journal = runtime?.journalReader
        state = CodexDrawerState(
            terminalContext: terminals.codexTerminalContext,
            availability: runtime == nil
                ? .unsupportedVersion("Runtime unavailable")
                : .stopped
        )

        terminalSelectionObserver = terminals.$codexTerminalContext.sink {
            [weak self] context in
            self?.apply(.selectTerminal(context), executeCommands: false)
            self?.refreshJournalIfNeeded()
        }

        if let coordinator {
            stateTask = Task { [weak self] in
                let stream = await coordinator.states()
                for await sessions in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(
                        .receiveSessions(sessions),
                        executeCommands: false
                    )
                    self?.refreshJournalIfNeeded()
                }
            }
        }
        if let supervisor {
            availabilityTask = Task { [weak self] in
                let stream = await supervisor.availability()
                for await availability in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(
                        .receiveAvailability(availability),
                        executeCommands: false
                    )
                }
            }
        }
    }

    deinit {
        stateTask?.cancel()
        availabilityTask?.cancel()
        journalTask?.cancel()
    }

    var composer: String { state.composerText }
    var canTakeOver: Bool { coordinator != nil && state.canTakeOver }

    var backgroundActivity: CodexDrawerBackgroundActivity {
        state.backgroundActivity(excluding: state.selectedConversationKey)
    }

    func badge(for tab: TerminalTabRecord) -> CodexDrawerBadge? {
        guard tab.sessionName != nil, let tmux = tab.tmuxIdentity else {
            return nil
        }
        return state.badge(for: TerminalConversationKey(
            terminalTarget: tab.target,
            tmux: tmux
        ))
    }

    func editComposer(_ text: String) {
        apply(.editComposer(text), executeCommands: false)
    }

    func sendComposer() {
        apply(.sendComposer)
    }

    func setExpanded(_ expanded: Bool) {
        apply(.setExpanded(expanded), executeCommands: false)
        refreshJournalIfNeeded()
    }

    func resizeExpanded(fraction: Double) {
        apply(.resizeExpanded(fraction: fraction), executeCommands: false)
        refreshJournalIfNeeded()
    }

    func stopAndTakeOver() {
        apply(.requestTakeover)
    }

    func allowOnce(_ requestID: UUID) {
        apply(.allowOnce(requestID))
    }

    func deny(_ requestID: UUID) {
        apply(.deny(requestID))
    }

    func retryAvailability() {
        apply(.retryAvailability)
    }

    private func apply(
        _ action: CodexDrawerAction,
        executeCommands: Bool = true
    ) {
        var next = state
        let commands = next.reduce(action)
        state = next
        guard executeCommands else { return }
        for command in commands { execute(command) }
    }

    private func execute(_ command: CodexDrawerCommand) {
        switch command {
        case let .submit(prompt, key), let .steer(prompt, key):
            guard let coordinator else { return }
            Task { await coordinator.submit(prompt, for: key) }
        case let .stopAndTakeOver(key):
            guard let coordinator else {
                apply(.takeoverCompleted(key), executeCommands: false)
                return
            }
            Task { [weak self] in
                // The coordinator returns only after router interruption has
                // restored terminal keyboard ownership. No terminal bytes or
                // process lifecycle action belongs on this path.
                let completion = await CodexDrawerCommandSequencer
                    .stopAndTakeOver(key) {
                        await coordinator.stopAndTakeOver(key)
                    }
                self?.apply(completion, executeCommands: false)
            }
        case let .allowOnce(requestID):
            guard let coordinator else { return }
            Task { await coordinator.approve(requestID) }
        case let .deny(requestID):
            guard let coordinator else { return }
            Task { await coordinator.deny(requestID) }
        case .retryAvailability:
            guard let supervisor else { return }
            Task { await supervisor.retryAvailability() }
        }
    }

    private func refreshJournalIfNeeded() {
        journalTask?.cancel()
        guard state.isExpanded,
            let key = state.selectedConversationKey,
            let journal
        else {
            operations = []
            journalNotice = nil
            journalHistoryNotice = nil
            return
        }
        journalTask = Task { [weak self] in
            do {
                let page = try await journal.recentEntries(
                    for: key,
                    request: TerminalJournalReadPageRequest(
                        maximumEventCount: 400,
                        maximumByteCount: 256 * 1024
                    )
                )
                try Task.checkCancellation()
                self?.operations = Self.group(page.entries)
                self?.journalNotice = nil
                self?.journalHistoryNotice = page.hasTruncatedHistory
                    ? "Showing recent journal history. Older or oversized details remain in the complete audit log."
                    : nil
            } catch is CancellationError {
                return
            } catch {
                self?.operations = []
                self?.journalHistoryNotice = nil
                self?.journalNotice =
                    "The operation journal is temporarily unavailable."
            }
        }
    }

    private static func group(
        _ entries: [TerminalJournalEvent]
    ) -> [CodexOperationRecord] {
        var order: [UUID] = []
        var groups: [UUID: [TerminalJournalEvent]] = [:]
        for entry in entries {
            if groups[entry.operationID] == nil { order.append(entry.operationID) }
            groups[entry.operationID, default: []].append(entry)
        }
        return order.suffix(50).reversed().compactMap { id in
            groups[id].map { CodexOperationRecord(id: id, events: $0) }
        }
    }
}
