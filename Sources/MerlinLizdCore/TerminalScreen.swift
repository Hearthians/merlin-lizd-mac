public struct TerminalCursor: Codable, Equatable, Sendable {
    public let row: Int
    public let column: Int
    public let isVisible: Bool

    public init(row: Int, column: Int, isVisible: Bool) {
        self.row = row
        self.column = column
        self.isVisible = isVisible
    }
}

public enum TerminalKeyboardMode: Codable, Equatable, Sendable {
    case normal
    case applicationCursor
}

public struct TerminalScreenMode: Codable, Equatable, Sendable {
    public static let normal = TerminalScreenMode(
        isAlternateScreen: false,
        keyboardMode: .normal
    )

    public let isAlternateScreen: Bool
    public let keyboardMode: TerminalKeyboardMode

    public init(
        isAlternateScreen: Bool,
        keyboardMode: TerminalKeyboardMode
    ) {
        self.isAlternateScreen = isAlternateScreen
        self.keyboardMode = keyboardMode
    }
}

public struct TerminalCellStyle: OptionSet, Codable, Hashable, Sendable {
    public static let bold = TerminalCellStyle(rawValue: 1 << 0)
    public static let underline = TerminalCellStyle(rawValue: 1 << 1)
    public static let inverse = TerminalCellStyle(rawValue: 1 << 2)
    public static let selected = TerminalCellStyle(rawValue: 1 << 3)
    public static let dim = TerminalCellStyle(rawValue: 1 << 4)
    public static let italic = TerminalCellStyle(rawValue: 1 << 5)

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public struct TerminalGridCell: Codable, Equatable, Sendable {
    /// A Unicode grapheme, a blank space, or an empty wide-cell continuation.
    public let grapheme: String
    public var style: TerminalCellStyle

    public init(
        grapheme: String,
        style: TerminalCellStyle = []
    ) {
        self.grapheme = grapheme
        self.style = style
    }
}

public struct TerminalGridFrame: Codable, Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cells: [TerminalGridCell]
    public let cursor: TerminalCursor
    public let mode: TerminalScreenMode

    public init(
        columns: Int,
        rows: Int,
        cells: [TerminalGridCell],
        cursor: TerminalCursor,
        mode: TerminalScreenMode
    ) {
        precondition(columns >= 0 && rows >= 0)
        precondition(cells.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.cells = cells
        self.cursor = cursor
        self.mode = mode
    }
}

public struct TerminalAttributeRun: Codable, Equatable, Sendable {
    public let row: Int
    public let startColumn: Int
    public let endColumn: Int
    public let style: TerminalCellStyle

    public init(
        row: Int,
        startColumn: Int,
        endColumn: Int,
        style: TerminalCellStyle
    ) {
        self.row = row
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.style = style
    }
}

public struct TerminalScreenSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let columns: Int
    public let rows: Int
    public let cursor: TerminalCursor
    public let mode: TerminalScreenMode
    public let text: String
    public let significantRuns: [TerminalAttributeRun]
    public let changedRows: [Int]

    public init(
        revision: UInt64,
        columns: Int,
        rows: Int,
        cursor: TerminalCursor,
        mode: TerminalScreenMode,
        text: String,
        significantRuns: [TerminalAttributeRun],
        changedRows: [Int]
    ) {
        self.revision = revision
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.mode = mode
        self.text = text
        self.significantRuns = significantRuns
        self.changedRows = changedRows
    }
}

public struct TerminalScreenReducer: Sendable {
    private struct Fingerprint: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let cursor: TerminalCursor
        let mode: TerminalScreenMode
        let text: String
        let significantRuns: [TerminalAttributeRun]
    }

    private struct RenderedRow: Equatable, Sendable {
        let cells: [TerminalGridCell]
    }

    private var revision: UInt64 = 0
    private var previousFingerprint: Fingerprint?
    private var previousRows: [RenderedRow] = []

    public init() {}

    public mutating func accept(
        _ frame: TerminalGridFrame
    ) -> TerminalScreenSnapshot {
        let rows = renderedRows(frame)
        let text = rows.map(renderedText).joined(separator: "\n")
        let runs = significantRuns(frame)
        let fingerprint = Fingerprint(
            columns: frame.columns,
            rows: frame.rows,
            cursor: frame.cursor,
            mode: frame.mode,
            text: text,
            significantRuns: runs
        )

        guard fingerprint != previousFingerprint else {
            return snapshot(
                revision: revision,
                frame: frame,
                text: text,
                runs: runs,
                changedRows: []
            )
        }

        let changedRows: [Int]
        if previousFingerprint == nil
            || previousFingerprint?.columns != frame.columns
            || previousFingerprint?.rows != frame.rows
        {
            changedRows = Array(0..<frame.rows)
        } else {
            changedRows = rows.indices.filter { rows[$0] != previousRows[$0] }
        }

        revision += 1
        previousFingerprint = fingerprint
        previousRows = rows
        return snapshot(
            revision: revision,
            frame: frame,
            text: text,
            runs: runs,
            changedRows: changedRows
        )
    }

    private func renderedRows(
        _ frame: TerminalGridFrame
    ) -> [RenderedRow] {
        guard frame.columns > 0 else {
            return Array(repeating: RenderedRow(cells: []), count: frame.rows)
        }
        return (0..<frame.rows).map { row in
            let start = row * frame.columns
            return RenderedRow(
                cells: Array(frame.cells[start..<(start + frame.columns)])
            )
        }
    }

    private func renderedText(_ row: RenderedRow) -> String {
        guard let lastContent = row.cells.lastIndex(where: { cell in
            !cell.grapheme.isEmpty && cell.grapheme != " "
        }) else {
            return ""
        }
        return row.cells[...lastContent].map(\.grapheme).joined()
    }

    private func significantRuns(
        _ frame: TerminalGridFrame
    ) -> [TerminalAttributeRun] {
        var result: [TerminalAttributeRun] = []
        for row in 0..<frame.rows {
            var column = 0
            while column < frame.columns {
                let style = frame.cells[row * frame.columns + column].style
                guard !style.isEmpty else {
                    column += 1
                    continue
                }
                let start = column
                column += 1
                while column < frame.columns,
                    frame.cells[row * frame.columns + column].style == style
                {
                    column += 1
                }
                result.append(
                    TerminalAttributeRun(
                        row: row,
                        startColumn: start,
                        endColumn: column,
                        style: style
                    )
                )
            }
        }
        return result
    }

    private func snapshot(
        revision: UInt64,
        frame: TerminalGridFrame,
        text: String,
        runs: [TerminalAttributeRun],
        changedRows: [Int]
    ) -> TerminalScreenSnapshot {
        TerminalScreenSnapshot(
            revision: revision,
            columns: frame.columns,
            rows: frame.rows,
            cursor: frame.cursor,
            mode: frame.mode,
            text: text,
            significantRuns: runs,
            changedRows: changedRows
        )
    }
}
