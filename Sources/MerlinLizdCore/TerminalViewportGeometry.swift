public enum TerminalViewportGeometry {
    public static func cursor(
        bufferBaseRow: Int,
        bufferCursorRow: Int,
        displayTopRow: Int,
        cursorColumn: Int,
        columns: Int,
        rows: Int,
        isShown: Bool
    ) -> TerminalCursor {
        let visibleRow = bufferBaseRow + bufferCursorRow - displayTopRow
        let hasVisiblePosition = rows > 0
            && columns > 0
            && (0..<rows).contains(visibleRow)
            && (0..<columns).contains(cursorColumn)

        return TerminalCursor(
            row: min(max(0, visibleRow), max(0, rows - 1)),
            column: min(max(0, cursorColumn), max(0, columns - 1)),
            isVisible: isShown && hasVisiblePosition
        )
    }

    /// Mirrors SwiftTerm's renderer: selecting any column occupied by a wide
    /// glyph selects its leading cell and every continuation cell.
    public static func selectionMask(
        cellWidths: [Int],
        selectedColumns: Range<Int>?
    ) -> [Bool] {
        guard let selectedColumns else {
            return Array(repeating: false, count: cellWidths.count)
        }

        var result = Array(repeating: false, count: cellWidths.count)
        var continuationEnd = 0
        var continuationIsSelected = false

        for column in cellWidths.indices {
            let declaredWidth = cellWidths[column]
            if declaredWidth == 0, column < continuationEnd {
                result[column] = continuationIsSelected
                continue
            }

            let width = max(1, declaredWidth)
            let endColumn = column + width
            let isSelected = selectedColumns.lowerBound < endColumn
                && column < selectedColumns.upperBound
            result[column] = isSelected
            continuationEnd = min(cellWidths.count, endColumn)
            continuationIsSelected = isSelected
        }

        return result
    }
}
