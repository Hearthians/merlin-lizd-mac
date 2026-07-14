import Foundation
@testable import MerlinLizdCore

struct TerminalTabsModelRenameResult: Sendable {
    let identity: TmuxSessionIdentity
    let resolvedIdentity: TmuxSessionIdentity?
    let stateDuringRename: TerminalState
    let tabs: [TerminalTabRecord]
    let persisted: TerminalState

    func sessionName(for id: String) -> String? {
        tabs.first(where: { $0.id == id })?.sessionName
    }
}

enum TerminalTabsModelTestHarnessError: Error {
    case persistedStateMissing
}

enum TerminalTabsModelTestHarness {
    @MainActor
    static func runRenameRace() async throws -> TerminalTabsModelRenameResult {
        let originalTarget = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "Original Display",
            alias: "old_alias"
        )
        let relabeledTarget = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "Relabeled Display",
            alias: "new_alias"
        )
        let unrelatedTarget = TerminalTarget.devbox(
            sid: "dbx_246800",
            name: "Other Devbox",
            alias: "other_alias"
        )
        let identity = TmuxSessionIdentity(
            serverSessionID: "$3",
            createdAtEpoch: 100
        )
        let otherIdentity = TmuxSessionIdentity(
            serverSessionID: "$9",
            createdAtEpoch: 200
        )
        let state = PersistingTerminalTabState(tabs: [
            TerminalTabRecord(
                id: "initiator",
                title: "Initiator",
                target: originalTarget,
                sessionName: "training"
            ),
            TerminalTabRecord(
                id: "stable-copy",
                title: "Stable copy",
                target: relabeledTarget,
                sessionName: "stale-copy-name",
                tmuxIdentity: identity
            ),
            TerminalTabRecord(
                id: "legacy-copy",
                title: "Legacy copy",
                target: originalTarget,
                sessionName: "training"
            ),
            TerminalTabRecord(
                id: "relabeled-legacy",
                title: "Relabeled legacy",
                target: relabeledTarget,
                sessionName: "training"
            ),
            TerminalTabRecord(
                id: "unrelated-target",
                title: "Unrelated target",
                target: unrelatedTarget,
                sessionName: "unrelated-name",
                tmuxIdentity: identity
            ),
            TerminalTabRecord(
                id: "other-session",
                title: "Other session",
                target: relabeledTarget,
                sessionName: "other-session",
                tmuxIdentity: otherIdentity
            ),
        ])

        let renameRunner = SuspendedRenameRunner()
        let discovery = TmuxSessionDiscovery(
            processRunner: IdentityDiscoveryRunner(identity: identity)
        )
        let controller = TmuxSessionController(processRunner: renameRunner)

        let rename = Task {
            try await TerminalTabTmuxCoordinator.rename(
                tabID: "initiator",
                to: "renamed",
                state: state,
                controller: controller,
                discovery: discovery
            )
        }
        await renameRunner.waitUntilStarted()

        let resolvedIdentity = await TerminalTabTmuxCoordinator.resolveIdentity(
            for: "initiator",
            state: state,
            discovery: discovery
        )
        guard let stateDuringRename = state.persisted else {
            throw TerminalTabsModelTestHarnessError.persistedStateMissing
        }

        await renameRunner.finish()
        try await rename.value
        guard let persisted = state.persisted else {
            throw TerminalTabsModelTestHarnessError.persistedStateMissing
        }

        return TerminalTabsModelRenameResult(
            identity: identity,
            resolvedIdentity: resolvedIdentity,
            stateDuringRename: stateDuringRename,
            tabs: state.tabs,
            persisted: persisted
        )
    }
}

@MainActor
private final class PersistingTerminalTabState: TerminalTabTmuxStateStoring {
    private(set) var tabs: [TerminalTabRecord]
    private(set) var persisted: TerminalState?

    init(tabs: [TerminalTabRecord]) {
        self.tabs = tabs
    }

    func terminalTabsSnapshot() -> [TerminalTabRecord] {
        tabs
    }

    func replaceTerminalTabs(_ tabs: [TerminalTabRecord]) {
        self.tabs = tabs
    }

    func persistTerminalTabs() {
        let encoded = try? TerminalStateCodec.encode(
            TerminalState(selectedTabID: "initiator", tabs: tabs)
        )
        persisted = encoded.flatMap { try? TerminalStateCodec.decode($0) }
    }
}

private actor SuspendedRenameRunner: InventoryProcessRunning {
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        started = true
        await withCheckedContinuation { gate = $0 }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        gate?.resume()
        gate = nil
    }
}

private actor IdentityDiscoveryRunner: InventoryProcessRunning {
    let identity: TmuxSessionIdentity

    init(identity: TmuxSessionIdentity) {
        self.identity = identity
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        .init(
            stdout: "training,\(identity.serverSessionID),\(identity.createdAtEpoch)\n",
            stderr: "",
            exitCode: 0
        )
    }
}
