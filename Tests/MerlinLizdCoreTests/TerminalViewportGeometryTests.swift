import Testing
@testable import MerlinLizdCore

@Suite("Terminal viewport geometry")
struct TerminalViewportGeometryTests {
    @Test("cursor uses the display offset and hides outside the viewport")
    func cursorTracksDisplayedScrollback() {
        #expect(
            TerminalViewportGeometry.cursor(
                bufferBaseRow: 12,
                bufferCursorRow: 3,
                displayTopRow: 10,
                cursorColumn: 4,
                columns: 8,
                rows: 6,
                isShown: true
            ) == .init(row: 5, column: 4, isVisible: true)
        )

        #expect(
            TerminalViewportGeometry.cursor(
                bufferBaseRow: 12,
                bufferCursorRow: 3,
                displayTopRow: 4,
                cursorColumn: 4,
                columns: 8,
                rows: 6,
                isShown: true
            ) == .init(row: 5, column: 4, isVisible: false)
        )

        #expect(
            TerminalViewportGeometry.cursor(
                bufferBaseRow: 12,
                bufferCursorRow: 3,
                displayTopRow: 10,
                cursorColumn: 4,
                columns: 8,
                rows: 6,
                isShown: false
            ).isVisible == false
        )
    }

    @Test("selection intersects an entire wide glyph and its continuation")
    func selectionMatchesWideGlyphRendering() {
        let widths = [1, 2, 0, 1]

        #expect(
            TerminalViewportGeometry.selectionMask(
                cellWidths: widths,
                selectedColumns: 2..<3
            ) == [false, true, true, false]
        )
        #expect(
            TerminalViewportGeometry.selectionMask(
                cellWidths: widths,
                selectedColumns: 1..<2
            ) == [false, true, true, false]
        )
        #expect(
            TerminalViewportGeometry.selectionMask(
                cellWidths: widths,
                selectedColumns: 3..<4
            ) == [false, false, false, true]
        )
    }
}
