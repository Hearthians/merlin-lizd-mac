import Testing
@testable import MerlinLizdCore

@Suite("Terminal tab tmux identity integration", .serialized)
struct TerminalTabsModelTests {
    @Test("rename uses identity resolved during suspension and persists fan-out")
    func renameUsesPostAwaitIdentity() async throws {
        let result = try await TerminalTabsModelTestHarness.runRenameRace()

        #expect(result.resolvedIdentity == result.identity)
        #expect(
            result.stateDuringRename.tabs.first {
                $0.id == "initiator"
            }?.tmuxIdentity == result.identity
        )
        #expect(result.sessionName(for: "initiator") == "renamed")
        #expect(result.sessionName(for: "stable-copy") == "renamed")
        #expect(result.sessionName(for: "legacy-copy") == "renamed")
        #expect(result.sessionName(for: "relabeled-legacy") == "training")
        #expect(result.sessionName(for: "unrelated-target") == "unrelated-name")
        #expect(result.sessionName(for: "other-session") == "other-session")
        #expect(result.persisted.tabs == result.tabs)
        #expect(
            result.persisted.tabs.first {
                $0.id == "initiator"
            }?.tmuxIdentity == result.identity
        )
    }
}
