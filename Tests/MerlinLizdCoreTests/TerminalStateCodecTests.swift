import Testing
@testable import MerlinLizdCore

@Suite("Terminal tab persistence")
struct TerminalStateCodecTests {
    @Test("cycles terminal tabs in both directions")
    func cyclesTerminalTabs() {
        let ids = ["first", "second", "third"]

        #expect(TerminalTabSelection.next(in: ids, from: "first") == "second")
        #expect(TerminalTabSelection.next(in: ids, from: "third") == "first")
        #expect(TerminalTabSelection.previous(in: ids, from: "third") == "second")
        #expect(TerminalTabSelection.previous(in: ids, from: "first") == "third")
    }

    @Test("selects a deterministic edge when no terminal tab is active")
    func selectsEdgeWithoutActiveTab() {
        let ids = ["first", "second", "third"]

        #expect(TerminalTabSelection.next(in: ids, from: nil) == "first")
        #expect(TerminalTabSelection.previous(in: ids, from: nil) == "third")
        #expect(TerminalTabSelection.next(in: [], from: nil) == nil)
        #expect(TerminalTabSelection.previous(in: [], from: nil) == nil)
    }

    @Test("only Option-closing a tmux tab requests termination confirmation")
    func resolvesCloseDisposition() {
        let localTab = TerminalTabRecord(
            id: "local",
            title: "Local",
            target: .local,
            sessionName: nil
        )
        let tmuxTab = TerminalTabRecord(
            id: "remote",
            title: "Remote",
            target: .devbox(sid: "dbx_123", name: "devbox", alias: "devbox"),
            sessionName: "mlz-work"
        )

        #expect(
            TerminalTabCloseDisposition.resolve(for: localTab, optionPressed: false) == .closeTab
        )
        #expect(
            TerminalTabCloseDisposition.resolve(for: tmuxTab, optionPressed: false) == .closeTab
        )
        #expect(
            TerminalTabCloseDisposition.resolve(for: localTab, optionPressed: true) == .closeTab
        )
        #expect(
            TerminalTabCloseDisposition.resolve(for: tmuxTab, optionPressed: true) == .confirmTmuxTermination
        )
    }

    @Test("persists a renamed tmux session for later reconnection")
    func persistsRenamedSession() throws {
        var tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Training",
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3959909"
            ),
            sessionName: "mlz-old"
        )

        tab.sessionName = "training-main"
        let encoded = try TerminalStateCodec.encode(
            TerminalState(selectedTabID: tab.id, tabs: [tab])
        )
        let decoded = try TerminalStateCodec.decode(encoded)

        #expect(decoded.tabs.first?.sessionName == "training-main")
        #expect(!encoded.contains("mlz-old"))
    }

    @Test("restores target and tmux metadata without persisting connection secrets")
    func roundTripsTerminalTabs() throws {
        let state = TerminalState(
            selectedTabID: "tab-worker",
            tabs: [
                TerminalTabRecord(
                    id: "tab-local",
                    title: "Local",
                    target: .local,
                    sessionName: nil
                ),
                TerminalTabRecord(
                    id: "tab-worker",
                    title: "L40 · 3959909",
                    target: .worker(
                        devboxSID: "dbx_135679",
                        devboxName: "wt_hl",
                        alias: "hl_gpu_2",
                        workerID: "3959909"
                    ),
                    sessionName: "merlin-lizd-train"
                ),
            ]
        )

        let encoded = try TerminalStateCodec.encode(state)
        let decoded = try TerminalStateCodec.decode(encoded)

        #expect(decoded == state)
        #expect(!encoded.contains("ProxyCommand"))
        #expect(!encoded.contains("ssh_proxy_cmd"))
    }
}
