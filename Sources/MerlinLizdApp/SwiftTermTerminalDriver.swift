import Foundation
import MerlinLizdCore

enum SwiftTermTerminalDriverError: Error, Equatable {
    case disconnected
    case staleRevision(expected: UInt64, actual: UInt64)
}

@MainActor
final class SwiftTermTerminalDriver: TerminalSessionPort {
    let terminalView: AgentTerminalView

    private let channel: TerminalScreenChannel<ContinuousClock>
    private var reducer = TerminalScreenReducer()
    private var snapshot: TerminalScreenSnapshot
    private var isConnected = true
    private var waitTasks: [
        UUID: Task<TerminalScreenWaitResult, any Error>
    ] = [:]
    private var inputTasks: [UUID: Task<Void, any Error>] = [:]

    init(terminalView: AgentTerminalView) {
        let initial = TerminalScreenSnapshot(
            revision: 0,
            columns: 0,
            rows: 0,
            cursor: .init(row: 0, column: 0, isVisible: false),
            mode: .normal,
            text: "",
            significantRuns: [],
            changedRows: []
        )
        self.terminalView = terminalView
        snapshot = initial
        channel = TerminalScreenChannel(
            initial: initial,
            clock: ContinuousClock()
        )
        terminalView.onRenderedFrame = { [weak self] frame in
            self?.publish(frame)
        }
    }

    var keyboardOwner: TerminalKeyboardOwner {
        terminalView.keyboardOwner
    }

    func observeScreen() async throws -> TerminalScreenSnapshot {
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        return snapshot
    }

    func sendInput(
        _ batch: TerminalInputBatch
    ) async throws -> TerminalInputReceipt {
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        guard batch.expectedRevision == snapshot.revision else {
            throw SwiftTermTerminalDriverError.staleRevision(
                expected: batch.expectedRevision,
                actual: snapshot.revision
            )
        }
        let bytes = try TerminalInputEncoder.encode(
            events: batch.events,
            keyboardMode: snapshot.mode.keyboardMode
        )
        let id = UUID()
        let task = Task {
            try await terminalView.sendAgentBytes(Array(bytes))
        }
        inputTasks[id] = task
        defer { inputTasks.removeValue(forKey: id) }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if !isConnected {
                throw SwiftTermTerminalDriverError.disconnected
            }
            throw CancellationError()
        }

        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        return TerminalInputReceipt(
            acceptedRevision: batch.expectedRevision,
            byteCount: bytes.count
        )
    }

    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        await channel.publish(snapshot)
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }

        let id = UUID()
        let task = Task {
            try await channel.wait(request)
        }
        waitTasks[id] = task
        defer { waitTasks.removeValue(forKey: id) }

        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if !isConnected {
                throw SwiftTermTerminalDriverError.disconnected
            }
            throw CancellationError()
        }
    }

    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) async {
        terminalView.keyboardOwner = isConnected ? owner : .user
    }

    func disconnect() {
        guard isConnected else {
            return
        }
        isConnected = false
        terminalView.keyboardOwner = .user
        terminalView.onRenderedFrame = nil

        let waits = Array(waitTasks.values)
        waitTasks.removeAll()
        waits.forEach { $0.cancel() }

        let inputs = Array(inputTasks.values)
        inputTasks.removeAll()
        inputs.forEach { $0.cancel() }
    }

    private func publish(_ frame: TerminalGridFrame) {
        guard isConnected else {
            return
        }
        let next = reducer.accept(frame)
        snapshot = next
        Task { await channel.publish(next) }
    }
}
