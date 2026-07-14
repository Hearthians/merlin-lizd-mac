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

struct TerminalTabsModelRecreationResult: Sendable {
    let originalIdentity: TmuxSessionIdentity
    let replacementIdentity: TmuxSessionIdentity
    let resolvedDuringMutation: TmuxSessionIdentity?
    let command: CommandSpec?
    let tabs: [TerminalTabRecord]
    let persisted: TerminalState

    func tab(for id: String) -> TerminalTabRecord? {
        tabs.first(where: { $0.id == id })
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
        let discoveryRunner = IdentityDiscoveryRunner(identity: identity)
        let discovery = TmuxSessionDiscovery(processRunner: discoveryRunner)
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
        await discoveryRunner.waitUntilStarted()
        let resolution = Task {
            await TerminalTabTmuxCoordinator.resolveIdentity(
                for: "initiator",
                state: state,
                discovery: discovery
            )
        }
        await discoveryRunner.finish()
        let resolvedIdentity = await resolution.value
        await renameRunner.waitUntilStarted()
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

    @MainActor
    static func runSameNameRecreationRace() async throws
        -> TerminalTabsModelRecreationResult
    {
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
        let originalIdentity = TmuxSessionIdentity(
            serverSessionID: "$3",
            createdAtEpoch: 100
        )
        let replacementIdentity = TmuxSessionIdentity(
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
                id: "original-copy",
                title: "Original copy",
                target: relabeledTarget,
                sessionName: "original-stale-name",
                tmuxIdentity: originalIdentity
            ),
            TerminalTabRecord(
                id: "replacement-copy",
                title: "Replacement copy",
                target: relabeledTarget,
                sessionName: "replacement-stale-name",
                tmuxIdentity: replacementIdentity
            ),
        ])
        let runner = SameNameRecreationRunner(
            originalIdentity: originalIdentity,
            replacementIdentity: replacementIdentity
        )
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let controller = TmuxSessionController(processRunner: runner)

        let rename = Task {
            try await TerminalTabTmuxCoordinator.rename(
                tabID: "initiator",
                to: "renamed",
                state: state,
                controller: controller,
                discovery: discovery
            )
        }
        await runner.waitUntilRenameStarted()

        let resolvedDuringMutation = await TerminalTabTmuxCoordinator
            .resolveIdentity(
                for: "initiator",
                state: state,
                discovery: discovery
            )

        await runner.finishRename()
        try await rename.value
        guard let persisted = state.persisted else {
            throw TerminalTabsModelTestHarnessError.persistedStateMissing
        }

        return TerminalTabsModelRecreationResult(
            originalIdentity: originalIdentity,
            replacementIdentity: replacementIdentity,
            resolvedDuringMutation: resolvedDuringMutation,
            command: await runner.renameCommand(),
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
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?

    init(identity: TmuxSessionIdentity) {
        self.identity = identity
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        started = true
        await withCheckedContinuation { gate = $0 }
        return .init(
            stdout: "training,\(identity.serverSessionID),\(identity.createdAtEpoch)\n",
            stderr: "",
            exitCode: 0
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        gate?.resume()
        gate = nil
    }
}

private actor SameNameRecreationRunner: InventoryProcessRunning {
    let originalIdentity: TmuxSessionIdentity
    let replacementIdentity: TmuxSessionIdentity
    private var renameStarted = false
    private var renameGate: CheckedContinuation<Void, Never>?
    private var recordedRenameCommand: CommandSpec?

    init(
        originalIdentity: TmuxSessionIdentity,
        replacementIdentity: TmuxSessionIdentity
    ) {
        self.originalIdentity = originalIdentity
        self.replacementIdentity = replacementIdentity
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.last?.contains("rename-session") == true {
            recordedRenameCommand = command
            renameStarted = true
            await withCheckedContinuation { renameGate = $0 }
            return .init(stdout: "", stderr: "", exitCode: 0)
        }

        let identity = renameStarted ? replacementIdentity : originalIdentity
        return .init(
            stdout: "training,\(identity.serverSessionID),\(identity.createdAtEpoch)\n",
            stderr: "",
            exitCode: 0
        )
    }

    func waitUntilRenameStarted() async {
        while !renameStarted { await Task.yield() }
    }

    func finishRename() {
        renameGate?.resume()
        renameGate = nil
    }

    func renameCommand() -> CommandSpec? {
        recordedRenameCommand
    }
}
