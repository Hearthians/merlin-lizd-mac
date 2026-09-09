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
