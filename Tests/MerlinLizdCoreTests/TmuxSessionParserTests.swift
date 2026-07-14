import Testing
@testable import MerlinLizdCore

@Suite("tmux session discovery")
struct TmuxSessionParserTests {
    @Test("structured tmux output preserves server identity")
    func parsesStructuredIdentity() {
        let records = TmuxSessionParser.parse("training,$3,1784000102\n")

        #expect(records == [TmuxSessionRecord(
            name: "training",
            identity: .init(
                serverSessionID: "$3",
                createdAtEpoch: 1_784_000_102
            )
        )])
    }

    @Test("deduplicates structured output by server identity")
    func deduplicatesStructuredIdentity() {
        let records = TmuxSessionParser.parse("""
        training,$3,100
        renamed-training,$3,100
        evaluation,$4,101
        """)

        #expect(records.map(\.name) == ["training", "evaluation"])
        #expect(records.map(\.id) == ["$3@100", "$4@101"])
    }

    @Test("rejects malformed structured identities")
    func rejectsMalformedStructuredIdentities() {
        let records = TmuxSessionParser.parse("""
        missing-dollar,3,100
        negative-created,$4,-1
        invalid-created,$5,today
        extra-field,$6,100,unexpected
        """)

        #expect(records.isEmpty)
    }

    @Test("same-name recreated sessions have distinct identities")
    func distinguishesSameNameRecreation() {
        let records = TmuxSessionParser.parse("""
        training,$3,100
        training,$9,200
        """)

        #expect(records.map(\.name) == ["training", "training"])
        #expect(records.map(\.id) == ["$3@100", "$9@200"])
        #expect(Set(records).count == 2)
    }

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
        #expect(sessions.allSatisfy { $0.identity == nil })
    }
}
