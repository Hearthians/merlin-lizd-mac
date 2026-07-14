import Testing
@testable import MerlinLizdCore

@Suite("Terminal tab persistence")
struct TerminalStateCodecTests {
    @Test("decodes legacy terminal tabs without tmux identity")
    func decodesLegacyTabWithoutTmuxIdentity() throws {
        let legacyJSON = #"{"selectedTabID":"tab-local","tabs":[{"id":"tab-local","sessionName":"training","target":{"local":{}},"title":"Local"}]}"#

        let decoded = try TerminalStateCodec.decode(legacyJSON)

        #expect(decoded.tabs.first?.tmuxIdentity == nil)
    }

    @Test("round-trips stable tmux identity")
    func roundTripsTmuxIdentity() throws {
        let tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Training",
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3959909"
            ),
            sessionName: "training",
            tmuxIdentity: .init(
                serverSessionID: "$3",
                createdAtEpoch: 1_784_000_102
            )
        )

        let encoded = try TerminalStateCodec.encode(
            TerminalState(selectedTabID: tab.id, tabs: [tab])
        )
        let decoded = try TerminalStateCodec.decode(encoded)

        #expect(decoded.tabs == [tab])
        #expect(decoded.tabs.first?.tmuxIdentity == tab.tmuxIdentity)
    }

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
