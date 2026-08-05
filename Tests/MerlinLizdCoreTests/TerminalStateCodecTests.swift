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

    @Test("removes a legacy embedded session name from the context title")
    func normalizesLegacySessionTitle() {
        let tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Worker 3959909 · training-main",
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3959909"
            ),
            sessionName: "training-main"
        )

        #expect(tab.sessionContextTitle == "Worker 3959909")
    }

    @Test("keeps context titles that only resemble the session name")
    func keepsDistinctContextTitle() {
        let tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Training training-main-old",
            target: .local,
            sessionName: "training-main"
        )

        #expect(tab.sessionContextTitle == "Training training-main-old")
    }

    @Test("omits an empty context title without hiding a user title")
    func handlesEmptyAndSessionOnlyContextTitles() {
        let empty = TerminalTabRecord(
            id: "empty",
            title: "",
            target: .local,
            sessionName: "training-main"
        )
        let sessionOnly = TerminalTabRecord(
            id: "session-only",
            title: "training-main",
            target: .local,
            sessionName: "training-main"
        )

        #expect(empty.sessionContextTitle == nil)
        #expect(sessionOnly.sessionContextTitle == "training-main")
    }

    @Test("renaming a session canonicalizes its legacy title")
    func renamesSessionAndNormalizesTitle() {
        var tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Worker 3959909 · mlz-old",
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3959909"
            ),
            sessionName: "mlz-old"
        )

        let renamed = tab.recordSessionRename(
            from: "mlz-old",
            to: "training-main"
        )

        #expect(renamed)
        #expect(tab.title == "Worker 3959909")
        #expect(tab.sessionName == "training-main")
    }

    @Test("renaming a session preserves a user-authored suffix")
    func preservesCustomTitleDuringSessionRename() {
        var tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Production · mlz-old",
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3959909"
            ),
            sessionName: "mlz-old"
        )

        tab.recordSessionRename(from: "mlz-old", to: "training-main")

        #expect(tab.title == "Production · mlz-old")
        #expect(tab.sessionContextTitle == "Production · mlz-old")
    }

    @Test("a stale session rename leaves the tab unchanged")
    func rejectsStaleSessionRename() {
        var tab = TerminalTabRecord(
            id: "tab-worker",
            title: "Worker 3959909",
            target: .local,
            sessionName: "current-session"
        )

        let renamed = tab.recordSessionRename(
            from: "stale-session",
            to: "new-session"
        )

        #expect(!renamed)
        #expect(tab.title == "Worker 3959909")
        #expect(tab.sessionName == "current-session")
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
                    sessionName: "merlin-lizd-train",
                    workingDirectory: "/mnt/training"
                ),
                TerminalTabRecord(
                    id: "tab-task",
                    title: "training · worker-1",
                    target: .task(
                        runID: "026d090ddd50fc87",
                        name: "training",
                        instanceID: "worker_1",
                        alias: "026d090ddd50fc87.worker_1.job.lizhuodong"
                            + "@merlin-ssh-proxy-cn.byted.org"
                    ),
                    sessionName: "mlz-task"
                ),
            ]
        )

        let encoded = try TerminalStateCodec.encode(state)
        let decoded = try TerminalStateCodec.decode(encoded)

        #expect(decoded == state)
        #expect(!encoded.contains("ProxyCommand"))
        #expect(!encoded.contains("ssh_proxy_cmd"))
        #expect(!encoded.contains("access_token"))
    }

    @Test("restores older tabs without a working directory")
    func decodesLegacyTerminalTab() throws {
        let encoded =
            #"{"selectedTabID":"tab-local","tabs":[{"id":"tab-local","sessionName":null,"target":{"local":{}},"title":"Local"}]}"#

        let decoded = try TerminalStateCodec.decode(encoded)

        #expect(decoded.tabs.first?.workingDirectory == nil)
    }
}
