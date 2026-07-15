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
    private let inputLane = AcknowledgedOperationLane()

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
        try await synchronizeCurrentFrame()
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
        do {
            return try await inputLane.submit { @MainActor [weak self] in
                guard let self, self.isConnected else {
                    throw SwiftTermTerminalDriverError.disconnected
                }
                guard batch.expectedRevision == self.snapshot.revision else {
                    throw SwiftTermTerminalDriverError.staleRevision(
                        expected: batch.expectedRevision,
                        actual: self.snapshot.revision
                    )
                }

                try await self.terminalView.sendAgentBytes(Array(bytes))
                guard self.isConnected else {
                    throw SwiftTermTerminalDriverError.disconnected
                }
                return TerminalInputReceipt(
                    acceptedRevision: batch.expectedRevision,
                    byteCount: bytes.count
                )
            }
        } catch AcknowledgedOperationLaneError.disconnected {
            throw SwiftTermTerminalDriverError.disconnected
        }
    }

    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        try await synchronizeCurrentFrame()

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

        inputLane.disconnect()
    }

    private func publish(_ frame: TerminalGridFrame) {
        guard isConnected else {
            return
        }
        let previousRevision = snapshot.revision
        let next = reducer.accept(frame)
        guard next.revision > previousRevision else {
            return
        }
        snapshot = next
        Task { await channel.publish(next) }
    }

    private func synchronizeCurrentFrame() async throws {
        let previousRevision = snapshot.revision
        terminalView.refreshRenderedFrame()
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
        guard snapshot.revision > previousRevision else {
            return
        }
        await channel.publish(snapshot)
        guard isConnected else {
            throw SwiftTermTerminalDriverError.disconnected
        }
    }
}
