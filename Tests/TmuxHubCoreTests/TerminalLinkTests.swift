import SwiftTerm
import Testing

@Suite("Terminal file links")
struct TerminalLinkTests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("recognizes relative mesh paths shown by agent CLIs")
    func recognizesRelativePath() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "- temp_output/r256/production-indexed/r256-run3/CelloFill/38.ply\r\n")
        let link = terminal.link(
            at: .screen(Position(col: 10, row: 0)),
            mode: .explicitAndImplicit
        )
        #expect(link == "temp_output/r256/production-indexed/r256-run3/CelloFill/38.ply")
    }

    @Test("recognizes bare filenames in colored multi-column ls output")
    func recognizesColoredDirectoryListing() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 260, rows: 24)
        let files = [
            (name: "mesh2ovox.log", color: "0"),
            (name: "ovox2glb.log", color: "0"),
            (name: "ovox2mesh.log", color: "0"),
            (name: "ovoxel_helmet_visualization.png", color: "01;35"),
            (name: "ovoxel_helmet.vxz", color: "0"),
            (name: "rec_helmet.glb", color: "0"),
            (name: "rec_helmet.ply", color: "0"),
            (name: "render_ovox.log", color: "0"),
        ]
        terminal.feed(text: "\u{1B}[36mhelmet\u{1B}[0m $ ls\r\n")
        terminal.feed(text: files.map {
            "\u{1B}[\($0.color)m\($0.name)\u{1B}[0m"
        }.joined(separator: "  ") + "  \r\n")

        var startColumn = 0
        for file in files {
            let endColumn = startColumn + file.name.count
            for column in startColumn..<endColumn {
                #expect(terminal.link(
                    at: .screen(Position(col: column, row: 1)),
                    mode: .explicitAndImplicit
                ) == file.name)
            }
            for column in endColumn..<(endColumn + 2) {
                #expect(terminal.link(
                    at: .screen(Position(col: column, row: 1)),
                    mode: .explicitAndImplicit
                ) == nil)
            }
            startColumn = endColumn + 2
        }
    }

    @Test("keeps spaces between filenames across a soft wrap", arguments: [4, 6])
    func preservesSoftWrappedListingSpaces(spaceCount: Int) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 12, rows: 24)
        let first = "mesh.ply"
        let second = "rec.ply"
        let text = first + String(repeating: " ", count: spaceCount) + second
        terminal.feed(text: text)

        for (offset, character) in text.enumerated() {
            let expected = character.isWhitespace ? nil : (offset < first.count ? first : second)
            #expect(terminal.link(
                at: .screen(Position(col: offset % 12, row: offset / 12)),
                mode: .explicitAndImplicit
            ) == expected)
        }
    }

    @Test("recognizes a single filename across soft wraps")
    func recognizesSoftWrappedFilename() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 12, rows: 24)
        let name = "ovoxel_helmet_visualization.png"
        terminal.feed(text: name)

        for offset in 0..<name.count {
            #expect(terminal.link(
                at: .screen(Position(col: offset % 12, row: offset / 12)),
                mode: .explicitAndImplicit
            ) == name)
        }
    }

    @Test("does not merge bare filenames on separate hard rows near the right edge")
    func keepsHardRowsSeparate() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 12, rows: 24)
        let names = ["mesh123.ply", "rec.ply"]
        terminal.feed(text: names.joined(separator: "\r\n") + "\r\n")

        for (row, name) in names.enumerated() {
            for column in 0..<name.count {
                #expect(terminal.link(
                    at: .screen(Position(col: column, row: row)),
                    mode: .explicitAndImplicit
                ) == name)
            }
            #expect(terminal.link(
                at: .screen(Position(col: name.count, row: row)),
                mode: .explicitAndImplicit
            ) == nil)
        }
    }

    @Test("keeps complete URLs and paths ahead of their filename fragments", arguments: [
        "https://example.com/mesh.ply",
        "outputs/mesh.ply",
    ])
    func prefersCompleteLinks(text: String) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: text + "\r\n")
        for column in 0..<text.count {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == text)
        }
    }

    @Test("does not treat prose, versions, or dotted command options as filenames", arguments: [
        "ordinary prose and not-a-path",
        "version v1.2.3 and 1.2.3",
        "--output.log --format.ply --preview.png",
    ])
    func ignoresNonFilenames(text: String) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: text + "\r\n")
        for column in 0..<text.count {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == nil)
        }
    }

    @Test("does not turn prose or command options into file links")
    func ignoresNonPaths() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "plain prose --output not-a-path\r\n")
        for column in [1, 12, 22] {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == nil)
        }
    }
}
