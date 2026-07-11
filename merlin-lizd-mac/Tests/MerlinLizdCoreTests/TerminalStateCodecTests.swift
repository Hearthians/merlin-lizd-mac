import Testing
@testable import MerlinLizdCore

@Suite("Terminal tab persistence")
struct TerminalStateCodecTests {
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
