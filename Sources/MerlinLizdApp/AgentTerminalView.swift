import Foundation
import MerlinLizdCore
@preconcurrency import SwiftTerm

enum AgentTerminalViewError: Error, Equatable {
    case processNotRunning
}

@MainActor
final class AgentTerminalView: LocalProcessTerminalView {
    var keyboardOwner: TerminalKeyboardOwner = .user
    var onRenderedFrame: ((TerminalGridFrame) -> Void)?

    private var cursorIsVisible = true

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onRenderedFrame?(renderedFrame())
    }

    override func send(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        guard keyboardOwner == .user else {
            return
        }
        super.send(source: source, data: data)
    }

    override func showCursor(source: Terminal) {
        super.showCursor(source: source)
        cursorIsVisible = true
    }

    override func hideCursor(source: Terminal) {
        super.hideCursor(source: source)
        cursorIsVisible = false
    }

    func sendAgentBytes(_ bytes: [UInt8]) async throws {
        guard process.running else {
            throw AgentTerminalViewError.processNotRunning
        }

        let completion = AcknowledgedWriteContinuation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else {
                    return
                }
                guard !Task.isCancelled else {
                    completion.finish(.failure(CancellationError()))
                    return
                }
                process.send(data: bytes[...]) { result in
                    completion.finish(result.mapError { $0 as any Error })
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    private func renderedFrame() -> TerminalGridFrame {
        let columns = max(0, terminal.cols)
        let rows = max(0, terminal.rows)
        let activeBuffer = terminal.buffer
        let selectionRanges = (0..<rows).map { row in
            selectedColumnsRange(
                row: activeBuffer.yDisp + row,
                cols: columns
            )
        }
        var cells: [TerminalGridCell] = []
        cells.reserveCapacity(columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                guard let character = terminal.getCharData(
                    col: column,
                    row: row
                ) else {
                    cells.append(.init(grapheme: " "))
                    continue
                }

                let grapheme: String
                if character.width == 0 {
                    grapheme = ""
                } else {
                    let value = terminal.getCharacter(for: character)
                    grapheme = value == "\0" ? " " : String(value)
                }

                cells.append(
                    TerminalGridCell(
                        grapheme: grapheme,
                        style: cellStyle(
                            character,
                            isSelected: selectionRanges[row]?.contains(column)
                                == true
                        )
                    )
                )
            }
        }

        return TerminalGridFrame(
            columns: columns,
            rows: rows,
            cells: cells,
            cursor: TerminalCursor(
                row: min(max(0, activeBuffer.y), max(0, rows - 1)),
                column: min(max(0, activeBuffer.x), max(0, columns - 1)),
                isVisible: cursorIsVisible && columns > 0 && rows > 0
            ),
            mode: TerminalScreenMode(
                isAlternateScreen: terminal.isCurrentBufferAlternate,
                keyboardMode: terminal.applicationCursor
                    ? .applicationCursor
                    : .normal
            )
        )
    }

    private func cellStyle(
        _ character: CharData,
        isSelected: Bool
    ) -> TerminalCellStyle {
        let source = character.attribute.style
        var style: TerminalCellStyle = []
        if source.contains(.bold) { style.insert(.bold) }
        if source.contains(.underline)
            || character.attribute.underlineStyle != .none
        {
            style.insert(.underline)
        }
        if source.contains(.inverse) { style.insert(.inverse) }
        if source.contains(.dim) { style.insert(.dim) }
        if source.contains(.italic) { style.insert(.italic) }
        if isSelected { style.insert(.selected) }
        return style
    }
}

private final class AcknowledgedWriteContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var pendingResult: Result<Void, any Error>?
    private var isFinished = false

    func install(
        _ continuation: CheckedContinuation<Void, any Error>
    ) -> Bool {
        lock.lock()
        if isFinished {
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result ?? .failure(CancellationError()))
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}
