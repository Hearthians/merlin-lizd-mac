import Testing
@testable import MerlinLizdCore

@Suite("Terminal screen")
struct TerminalScreenTests {
    @Test("renders shell rows without trailing blank cells")
    func rendersShellRowsWithoutTrailingBlankCells() {
        var reducer = TerminalScreenReducer()
        let frame = makeFrame(
            rows: [
                cells("hello$  "),
                [
                    .init(grapheme: "界"),
                    .init(grapheme: ""),
                    .init(grapheme: " "),
                    .init(grapheme: "x"),
                    .init(grapheme: " "),
                    .init(grapheme: " "),
                    .init(grapheme: " "),
                    .init(grapheme: " "),
                ],
                cells("        "),
            ],
            cursor: .init(row: 0, column: 6, isVisible: true)
        )

        let snapshot = reducer.accept(frame)

        #expect(snapshot.revision == 1)
        #expect(snapshot.columns == 8)
        #expect(snapshot.rows == 3)
        #expect(snapshot.cursor == .init(row: 0, column: 6, isVisible: true))
        #expect(snapshot.mode == .normal)
        #expect(snapshot.text == "hello$\n界 x\n")
        #expect(snapshot.significantRuns.isEmpty)
        #expect(snapshot.changedRows == [0, 1, 2])
    }

    @Test("increments only for rendered grid mode cursor or attributes")
    func incrementsOnlyForRenderedChanges() {
        var reducer = TerminalScreenReducer()
        let shell = makeFrame(
            rows: [cells("one "), cells("two ")],
            cursor: .init(row: 1, column: 3, isVisible: true)
        )

        let first = reducer.accept(shell)
        let duplicate = reducer.accept(shell)
        let cursorOnly = reducer.accept(
            replacing(
                shell,
                cursor: .init(row: 0, column: 3, isVisible: true)
            )
        )
        let alternate = reducer.accept(
            replacing(
                shell,
                cursor: .init(row: 0, column: 3, isVisible: true),
                mode: .init(
                    isAlternateScreen: true,
                    keyboardMode: .applicationCursor
                )
            )
        )

        #expect(first.revision == 1)
        #expect(duplicate.revision == 1)
        #expect(duplicate.changedRows.isEmpty)
        #expect(cursorOnly.revision == 2)
        #expect(cursorOnly.changedRows.isEmpty)
        #expect(alternate.revision == 3)
        #expect(alternate.changedRows.isEmpty)
        #expect(alternate.mode.isAlternateScreen)
        #expect(alternate.mode.keyboardMode == .applicationCursor)
    }

    @Test("compacts attributes in an alternate-screen Vim frame")
    func compactsAttributesInAlternateScreenVimFrame() {
        var reducer = TerminalScreenReducer()
        let plain = makeFrame(
            rows: [cells("main.swift"), cells("-- INSERT ")],
            cursor: .init(row: 0, column: 0, isVisible: false),
            mode: .init(
                isAlternateScreen: true,
                keyboardMode: .applicationCursor
            )
        )
        _ = reducer.accept(plain)

        var highlightedCells = plain.cells
        highlightedCells[0].style = [.inverse, .bold]
        highlightedCells[1].style = [.inverse, .bold]
        highlightedCells[10].style = [.selected, .underline]
        highlightedCells[11].style = [.selected, .underline]
        let highlighted = TerminalGridFrame(
            columns: plain.columns,
            rows: plain.rows,
            cells: highlightedCells,
            cursor: plain.cursor,
            mode: plain.mode
        )

        let snapshot = reducer.accept(highlighted)

        #expect(snapshot.revision == 2)
        #expect(snapshot.changedRows == [0, 1])
        #expect(snapshot.significantRuns == [
            .init(
                row: 0,
                startColumn: 0,
                endColumn: 2,
                style: [.bold, .inverse]
            ),
            .init(
                row: 1,
                startColumn: 0,
                endColumn: 2,
                style: [.underline, .selected]
            ),
        ])
    }

    @Test("reports only changed rows until a resize changes the grid")
    func reportsCompactRowDiffsAndResize() {
        var reducer = TerminalScreenReducer()
        let original = makeFrame(
            rows: [cells("aaa"), cells("bbb")],
            cursor: .init(row: 1, column: 2, isVisible: true)
        )
        _ = reducer.accept(original)

        let rowChange = makeFrame(
            rows: [cells("aaa"), cells("bxb")],
            cursor: original.cursor
        )
        let changed = reducer.accept(rowChange)
        let resized = reducer.accept(
            makeFrame(
                rows: [cells("aaa "), cells("bxb "), cells("new ")],
                cursor: .init(row: 2, column: 3, isVisible: true)
            )
        )

        #expect(changed.revision == 2)
        #expect(changed.changedRows == [1])
        #expect(resized.revision == 3)
        #expect(resized.columns == 4)
        #expect(resized.rows == 3)
        #expect(resized.changedRows == [0, 1, 2])
    }
}

private func cells(_ text: String) -> [TerminalGridCell] {
    text.map { TerminalGridCell(grapheme: String($0)) }
}

private func makeFrame(
    rows: [[TerminalGridCell]],
    cursor: TerminalCursor,
    mode: TerminalScreenMode = .normal
) -> TerminalGridFrame {
    TerminalGridFrame(
        columns: rows.first?.count ?? 0,
        rows: rows.count,
        cells: rows.flatMap { $0 },
        cursor: cursor,
        mode: mode
    )
}

private func replacing(
    _ frame: TerminalGridFrame,
    cursor: TerminalCursor,
    mode: TerminalScreenMode? = nil
) -> TerminalGridFrame {
    TerminalGridFrame(
        columns: frame.columns,
        rows: frame.rows,
        cells: frame.cells,
        cursor: cursor,
        mode: mode ?? frame.mode
    )
}
