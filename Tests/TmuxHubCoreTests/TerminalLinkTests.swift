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

    @Test("recognizes the colored result directory in a Chinese status line")
    func recognizesResultDirectory() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 180, rows: 24)
        let label = "hssd_thick_comparison_8"
        let path = "temp_output/" + label
        let prefix = "结果目录：" + label + " ("
        // Each of the five Chinese prefix characters occupies two cells.
        let firstColumn = 10 + label.count + 2
        terminal.feed(text: prefix + "\u{1b}[32m" + path + "\u{1b}[0m)\r\n")

        for column in firstColumn..<(firstColumn + path.count) {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == path)
        }
        for column in [0, 10, firstColumn - 1, firstColumn + path.count] {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == nil)
        }
    }

    @Test("recognizes extensionless directories with relative and explicit prefixes", arguments: [
        "outputs/run",
        "outputs/run/",
        "outputs/run-v2_8",
        "./outputs/run",
        "../outputs/run",
        "~/outputs/run",
        "/tmp/outputs/run",
        ".cache/results",
    ])
    func recognizesExtensionlessDirectory(path: String) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 180, rows: 24)
        terminal.feed(text: path + "\r\n")
        for column in 0..<path.count {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == path)
        }
        #expect(terminal.link(
            at: .screen(Position(col: path.count, row: 0)),
            mode: .explicitAndImplicit
        ) == nil)
    }

    @Test("keeps parenthesized directory links separate from surrounding prose")
    func keepsDirectoryBoundaries() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let path = "outputs/run"
        let text = "result (" + path + ") next step"
        terminal.feed(text: text + "\r\n")
        for column in 0..<text.count {
            let expected: String? = (8..<(8 + path.count)).contains(column) ? path : nil
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == expected)
        }
    }

    @Test("recognizes colored extensionless directories across real terminal wraps")
    func recognizesSoftWrappedDirectory() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 12, rows: 24)
        let path = "temp_output/hssd_thick_comparison_8/"
        let text = "(" + path + ")"
        terminal.feed(text: "\u{1b}[32m" + text + "\u{1b}[0m")

        for offset in 0..<text.count {
            let expected: String? = offset > 0 && offset <= path.count ? path : nil
            #expect(terminal.link(
                at: .screen(Position(col: offset % 12, row: offset / 12)),
                mode: .explicitAndImplicit
            ) == expected)
        }
    }

    @Test("does not merge extensionless directories on separate hard rows")
    func keepsDirectoryHardRowsSeparate() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: 12, rows: 24)
        let paths = ["outputs/run", "other/run"]
        terminal.feed(text: paths.joined(separator: "\r\n") + "\r\n")

        for (row, path) in paths.enumerated() {
            for column in 0..<path.count {
                #expect(terminal.link(
                    at: .screen(Position(col: column, row: row)),
                    mode: .explicitAndImplicit
                ) == path)
            }
            #expect(terminal.link(
                at: .screen(Position(col: path.count, row: row)),
                mode: .explicitAndImplicit
            ) == nil)
        }
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
        "https://localhost/outputs/run",
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

    @Test("preserves dotted relative paths after option and label separators", arguments: [
        "--output=outputs/mesh.ply",
        "result:outputs/mesh.ply",
    ])
    func recognizesDottedPathAfterSeparator(text: String) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let path = "outputs/mesh.ply"
        let firstColumn = text.count - path.count
        terminal.feed(text: text + "\r\n")
        for column in 0..<text.count {
            #expect(terminal.link(
                at: .screen(Position(col: column, row: 0)),
                mode: .explicitAndImplicit
            ) == (column >= firstColumn ? path : nil))
        }
    }

    @Test("does not treat prose, versions, or dotted command options as filenames", arguments: [
        "ordinary prose and not-a-path",
        "result directory hssd_thick_comparison_8 is ready",
        "--output/folder --input/other",
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
