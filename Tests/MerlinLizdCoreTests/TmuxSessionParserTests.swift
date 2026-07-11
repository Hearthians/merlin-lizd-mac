import Testing
@testable import MerlinLizdCore

@Suite("tmux session discovery")
struct TmuxSessionParserTests {
    @Test("keeps attachable session names and ignores warning text")
    func parsesAttachableNames() {
        let output = """
        mlz-shell
        external.train
        wt: 1 windows (created Thu Jul  9 23:55:43 2026)
        warning: terminal database unavailable
        unsafe session
        mlz-shell
        """

        let sessions = TmuxSessionParser.parse(output)

        #expect(sessions.map(\.name) == ["mlz-shell", "external.train", "wt"])
    }
}
