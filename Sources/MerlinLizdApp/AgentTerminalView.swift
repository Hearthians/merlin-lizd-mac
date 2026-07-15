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
    private var lastPublishedFrame: TerminalGridFrame?
    private var framePublicationDeferralDepth = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        framePublicationDeferralDepth += 1
        super.dataReceived(slice: slice)
        framePublicationDeferralDepth -= 1
        publishCurrentFrameIfChanged()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        publishCurrentFrameIfChanged()
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        publishCurrentFrameIfChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        framePublicationDeferralDepth += 1
        super.setFrameSize(newSize)
        framePublicationDeferralDepth -= 1
        publishCurrentFrameIfChanged()
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
        try Task.checkCancellation()
        guard process.running else {
            throw AgentTerminalViewError.processNotRunning
        }

        try await withCheckedThrowingContinuation { continuation in
            process.send(data: bytes[...]) { result in
                continuation.resume(
                    with: result.mapError { $0 as any Error }
                )
            }
        }
    }

    /// Captures and publishes the current user-visible viewport only when its
    /// immutable frame differs from the most recently published one.
    @discardableResult
    func refreshRenderedFrame() -> Bool {
        publishCurrentFrameIfChanged()
    }

    @discardableResult
    private func publishCurrentFrameIfChanged() -> Bool {
        guard framePublicationDeferralDepth == 0, let onRenderedFrame else {
            return false
        }
        let frame = renderedFrame()
        guard frame != lastPublishedFrame else {
            return false
        }
        lastPublishedFrame = frame
        onRenderedFrame(frame)
        return true
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
            let characters = (0..<columns).map { column in
                terminal.getCharData(col: column, row: row)
            }
            let selectedCells = TerminalViewportGeometry.selectionMask(
                cellWidths: characters.map { Int($0?.width ?? 1) },
                selectedColumns: selectionRanges[row]
            )

            for column in 0..<columns {
                guard let character = characters[column] else {
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
                            isSelected: selectedCells[column]
                        )
                    )
                )
            }
        }

        return TerminalGridFrame(
            columns: columns,
            rows: rows,
            cells: cells,
            cursor: TerminalViewportGeometry.cursor(
                bufferBaseRow: currentBufferBaseRow(rows: rows),
                bufferCursorRow: activeBuffer.y,
                displayTopRow: activeBuffer.yDisp,
                cursorColumn: activeBuffer.x,
                columns: columns,
                rows: rows,
                isShown: cursorIsVisible
            ),
            mode: TerminalScreenMode(
                isAlternateScreen: terminal.isCurrentBufferAlternate,
                keyboardMode: terminal.applicationCursor
                    ? .applicationCursor
                    : .normal
            )
        )
    }

    /// SwiftTerm keeps `Buffer.yBase` internal. Its public scroll-invariant
    /// line API exposes the same resident-line extent, so derive yBase as the
    /// live viewport's top row without widening the documented vendor patch.
    private func currentBufferBaseRow(rows: Int) -> Int {
        guard rows > 0 else { return 0 }

        let firstResidentRow = terminal.buffer.totalLinesTrimmed
        let maximumResidentCount = rows + max(0, terminal.options.scrollback)
        var lowerBound = 0
        var upperBound = maximumResidentCount + 1

        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            if terminal.getScrollInvariantLine(
                row: firstResidentRow + candidate
            ) != nil {
                lowerBound = candidate + 1
            } else {
                upperBound = candidate
            }
        }

        return max(0, lowerBound - rows)
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
