import Testing
@testable import MerlinLizdCore

@Suite("tmux session discovery")
struct TmuxSessionParserTests {
    @Test("keeps attachable session names and ignores warning text")
    func parsesAttachableNames() {
        let output = """
        mlz-shell
        external.train
        warning: terminal database unavailable
        unsafe session
        mlz-shell
        """

        let sessions = TmuxSessionParser.parse(output)

        #expect(sessions.map(\.name) == ["mlz-shell", "external.train"])
    }
}
