import SwiftTerm
import Testing

@Suite("Terminal wide-character cells")
struct TerminalCellTests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("CJK continuation cells inherit their leading cell's attributes", arguments: [
        "0",
        "2",
        "1;38;2;120;160;200;48;2;20;30;40",
        "7",
        "2;7;38;5;130;48;5;22",
    ])
    func continuationAttributes(sgr: String) throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}[\(sgr)m中文表格")

        for column in stride(from: 0, to: 8, by: 2) {
            let leading = try #require(terminal.getCharData(col: column, row: 0))
            let continuation = try #require(terminal.getCharData(col: column + 1, row: 0))
            #expect(leading.width == 2)
            #expect(continuation.width == 0)
            #expect(continuation.attribute == leading.attribute)
        }
    }

    @Test("incremental ASCII repaints do not expose white CJK continuation cells", arguments: ["X", " "])
    func partialRepaintPreservesBackground(replacement: String) throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}[2m中文表格")
        let original = try #require(terminal.getCharData(col: 0, row: 0)).attribute
        #expect(original.bg == .defaultColor)

        // A terminal multiplexer can overwrite the leading cells independently.
        // The former continuation cells are then visible as blank cells.
        for column in stride(from: 0, to: 8, by: 2) {
            terminal.feed(text: "\u{1b}[1;\(column + 1)H\(replacement)")
        }

        for column in 0..<8 {
            let cell = try #require(terminal.getCharData(col: column, row: 0))
            #expect(cell.attribute.bg == original.bg)
            #expect(!cell.attribute.style.contains(.inverse))
        }
    }

    @Test("insert-mode truncation preserves the current colors", arguments: [
        "0",
        "2;38;2;120;160;200;48;2;20;30;40",
    ])
    func insertionTruncatesWideCharacterWithCurrentColors(sgr: String) throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 10, rows: 4)
        terminal.feed(text: "12345678中")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[4h\u{1b}[\(sgr)mA")

        let inserted = try #require(terminal.getCharData(col: 0, row: 0))
        let truncated = try #require(terminal.getCharData(col: 9, row: 0))
        #expect(terminal.getCharacter(for: inserted) == "A")
        #expect(truncated.width == 1)
        #expect(truncated.attribute.fg == inserted.attribute.fg)
        #expect(truncated.attribute.bg == inserted.attribute.bg)
    }
}
