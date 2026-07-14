import Testing
@testable import MerlinLizdCore

@Suite("Terminal conversation identity")
struct TerminalConversationTests {
    @Test("target aliases and display names do not affect conversation identity")
    func ignoresMutableTargetLabels() {
        let tmux = TmuxSessionIdentity(
            serverSessionID: "$3",
            createdAtEpoch: 100
        )
        let original = TerminalConversationKey(
            terminalTarget: .devbox(
                sid: "dbx_135679",
                name: "Original Name",
                alias: "old_alias"
            ),
            tmux: tmux
        )
        let relabeled = TerminalConversationKey(
            terminalTarget: .devbox(
                sid: "dbx_135679",
                name: "New Name",
                alias: "new_alias"
            ),
            tmux: tmux
        )
        let workerOriginal = TerminalConversationKey(
            terminalTarget: .worker(
                devboxSID: "dbx_135679",
                devboxName: "Original Name",
                alias: "old_alias",
                workerID: "3960209"
            ),
            tmux: tmux
        )
        let workerRelabeled = TerminalConversationKey(
            terminalTarget: .worker(
                devboxSID: "dbx_135679",
                devboxName: "New Name",
                alias: "new_alias",
                workerID: "3960209"
            ),
            tmux: tmux
        )

        #expect(original == relabeled)
        #expect(workerOriginal == workerRelabeled)
    }

    @Test("tmux rename does not affect conversation identity")
    func ignoresTmuxRename() {
        let tmux = TmuxSessionIdentity(
            serverSessionID: "$3",
            createdAtEpoch: 100
        )
        let before = TmuxSessionRecord(name: "training", identity: tmux)
        let after = TmuxSessionRecord(name: "renamed", identity: tmux)

        let beforeKey = TerminalConversationKey(
            target: .local,
            tmux: before.identity!
        )
        let afterKey = TerminalConversationKey(
            target: .local,
            tmux: after.identity!
        )

        #expect(beforeKey == afterKey)
    }

    @Test("same-name recreation changes conversation identity")
    func distinguishesTmuxRecreation() {
        let original = TerminalConversationKey(
            target: .local,
            tmux: .init(serverSessionID: "$3", createdAtEpoch: 100)
        )
        let recreated = TerminalConversationKey(
            target: .local,
            tmux: .init(serverSessionID: "$9", createdAtEpoch: 200)
        )

        #expect(original != recreated)
    }
}
