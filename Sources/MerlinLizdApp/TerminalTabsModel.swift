import Foundation
import MerlinLizdCore
import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject {
    @Published private(set) var tabs: [TerminalTabRecord]
    @Published private var tmuxCreation = TmuxCreationCoordinator()
    @Published var selectedTabID: String? {
        didSet {
            persist()
            guard let selectedTab else { return }
            prioritize(selectedTab.target)
        }
    }

    private var sessions: [String: TerminalSession] = [:]
    private let defaults: UserDefaults
    private let managedTerminalCommands: ManagedTerminalCommandBuilder
    private let runtime: MerlinRemoteRuntime
    let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionController: TmuxSessionController
    private let externalTerminalLauncher = ExternalTerminalLauncher()
    private let persistenceKey = "terminal-state-v1"

    init(
        runtime: MerlinRemoteRuntime,
        defaults: UserDefaults = .standard
    ) {
        managedTerminalCommands = ManagedTerminalCommandBuilder(
            sshMasterPool: runtime.sshMasterPool
        )
        self.runtime = runtime
        tmuxSessionDiscovery = runtime.tmuxDiscovery
        tmuxSessionController = runtime.tmuxController
        self.defaults = defaults
        if
            let encoded = defaults.string(forKey: persistenceKey),
            let restored = try? TerminalStateCodec.decode(encoded)
        {
            tabs = restored.tabs
            selectedTabID = restored.tabs.contains(where: { $0.id == restored.selectedTabID })
                ? restored.selectedTabID
                : nil
        } else {
            tabs = []
            selectedTabID = nil
        }
        seedWarmupPriorities()
    }

    var selectedTab: TerminalTabRecord? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var pendingTmuxCreation: TmuxCreationDraft? {
        tmuxCreation.pending
    }

    func openLocal() {
        open(
            title: "本机",
            target: .local,
            sessionName: nil
        )
    }

    func openDevbox(_ machine: DevboxInventory) {
        guard let connectionTarget = machine.sshConnectionTarget else { return }
        requestTmuxCreation(
            title: machine.displayName,
            target: .devbox(
                sid: machine.devbox.sid,
                name: machine.devbox.name,
                alias: connectionTarget
            ),
            sessionName: makeSessionName(label: machine.displayName)
        )
    }

    func openWorker(_ worker: WorkerInventoryRecord, on machine: DevboxInventory) {
        guard let target = machine.workerTerminalTarget(for: worker) else {
            return
        }
        let label = machine.displayName
        requestTmuxCreation(
            title: "\(worker.gpuType ?? "Worker") · \(worker.id)",
            target: target,
            sessionName: makeSessionName(label: "\(label)-\(worker.id)")
        )
    }

    func reconcileRemoteRoutes(with snapshot: InventorySnapshot) {
        var migratedCreation = tmuxCreation
        if migratedCreation.retarget(using: snapshot) {
            tmuxCreation = migratedCreation
        }

        let current = TerminalState(
            selectedTabID: selectedTabID,
            tabs: tabs
        )
        let migrated = current.retargetingConnections(using: snapshot)
        let changedIDs = Set(zip(current.tabs, migrated.tabs).compactMap {
            old, new in old.target == new.target ? nil : old.id
        })
        guard !changedIDs.isEmpty else { return }

        let selectedSessionNeedsRestart = selectedTabID.map {
            changedIDs.contains($0) && sessions[$0] != nil
        } ?? false
        for id in changedIDs {
            sessions.removeValue(forKey: id)?.close()
        }
        tabs = migrated.tabs
        persist()

        let targets = Set(
            migrated.tabs.compactMap { tab in
                changedIDs.contains(tab.id) ? tab.target : nil
            }
        )
        for target in targets {
            runtime.prioritize(target)
        }
        if selectedSessionNeedsRestart, let selectedTabID {
            _ = session(for: selectedTabID)
        }
    }

    func createPendingTmux(
        sessionName proposedName: String,
        workingDirectory proposedDirectory: String
    ) throws {
        let result: TmuxCreationResult
        do {
            result = try tmuxCreation.create(
                sessionName: proposedName,
                workingDirectory: proposedDirectory
            )
        } catch let error as TmuxCreationError {
            switch error {
            case .unavailable:
                throw TerminalTabOperationError.sessionUnavailable
            case .invalidSessionName:
                throw TerminalTabOperationError.invalidSessionName
            case .invalidWorkingDirectory:
                throw TerminalTabOperationError.invalidWorkingDirectory
            }
        }

        open(
            title: result.draft.title,
            target: result.draft.target,
            sessionName: result.configuration.sessionName,
            workingDirectory: result.configuration.workingDirectory
        )
    }

    func cancelPendingTmuxCreation() {
        tmuxCreation.cancel()
    }

    func attachExistingSession(_ sessionName: String, target: TerminalTarget) {
        guard TmuxSessionParser.isAttachable(sessionName) else { return }
        open(
            title: target.sessionAttachmentTitle,
            target: target,
            sessionName: sessionName
        )
    }

    func knownTmuxSessions(for target: TerminalTarget) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return tabs.compactMap { tab in
            guard
                tab.target == target,
                let sessionName = tab.sessionName,
                TmuxSessionParser.isAttachable(sessionName),
                seen.insert(sessionName).inserted
            else {
                return nil
            }
            return TmuxSessionRecord(name: sessionName)
        }
    }

    func prioritize(_ target: TerminalTarget) {
        runtime.prioritize(target)
    }

    func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        if let existing = sessions[id] {
            switch existing.state {
            case .exited, .closed:
                reconnect(id)
            case .idle, .preparing, .blocked, .running:
                break
            }
        } else {
            _ = session(for: id)
        }
    }

    func selectPreviousTab() {
        guard let id = TerminalTabSelection.previous(
            in: tabs.map(\.id),
            from: selectedTabID
        ) else { return }
        select(id)
    }

    func selectNextTab() {
        guard let id = TerminalTabSelection.next(
            in: tabs.map(\.id),
            from: selectedTabID
        ) else { return }
        select(id)
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        close(selectedTabID)
    }

    func reconnect(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        sessions.removeValue(forKey: id)?.close()
        _ = session(for: id)
        selectedTabID = id
        objectWillChange.send()
    }

    func session(for id: String) -> TerminalSession? {
        if let existing = sessions[id] {
            return existing
        }
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return nil
        }

        do {
            let command = try command(for: tab, destination: .swiftTerm)
            let plainSSHCommand: CommandSpec?
            let startPreparation: TerminalSession.StartPreparation?
            if MerlinCommands.sshConnectionTarget(for: tab.target) != nil {
                plainSSHCommand = try managedTerminalCommands.plainSSHCommand(
                    target: tab.target
                )
                let discovery = tmuxSessionDiscovery
                let target = tab.target
                startPreparation = { forceRetry in
                    let result = if forceRetry {
                        await discovery.retryAttachment(target: target)
                    } else {
                        await discovery.preflightAttachment(target: target)
                    }
                    return switch result {
                    case .ready:
                        .startRequestedCommand
                    case .sshUnavailable:
                        .blocked(.sshUnavailable)
                    case .workerNotReady:
                        .blocked(.workerNotReady)
                    case .tmuxUnavailable:
                        .blocked(.tmuxUnavailable)
                    }
                }
            } else {
                plainSSHCommand = nil
                startPreparation = nil
            }
            let session = TerminalSession(
                id: UUID(uuidString: tab.id) ?? UUID(),
                command: command,
                plainSSHCommand: plainSSHCommand,
                currentDirectory: tab.target == .local
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : nil,
                terminalType: TerminalTerminfo.term(for: tab.target),
                startPreparation: startPreparation
            )
            sessions[id] = session
            return session
        } catch {
            return nil
        }
    }

    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.close()
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)
        if wasSelected {
            if tabs.indices.contains(index) {
                selectedTabID = tabs[index].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
        persist()
    }

    func rename(_ id: String, to proposedTitle: String) {
        let title = String(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        tabs[index].title = title
        persist()
    }

    func renameTmuxSession(_ id: String, to proposedName: String) async throws {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TmuxSessionParser.isAttachable(newName) else {
            throw TerminalTabOperationError.invalidSessionName
        }
        guard
            let tab = tabs.first(where: { $0.id == id }),
            let currentName = tab.sessionName
        else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        guard currentName != newName else { return }

        do {
            try await tmuxSessionController.rename(
                target: tab.target,
                from: currentName,
                to: newName
            )
        } catch let error as TmuxSessionMutationError {
            throw terminalOperationError(error)
        }

        await tmuxSessionDiscovery.recordRename(
            target: tab.target,
            from: currentName,
            to: newName
        )

        // The remote operation is authoritative. Persist its new identity only
        // if this tab still describes the session that was renamed.
        guard let currentIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard tabs[currentIndex].recordSessionRename(
            from: currentName,
            to: newName
        ) else { return }
        persist()
    }

    func terminateTmuxSessionAndClose(_ id: String) async throws {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            let sessionName = tab.sessionName
        else {
            throw TerminalTabOperationError.sessionUnavailable
        }

        do {
            try await tmuxSessionController.terminate(
                target: tab.target,
                sessionName: sessionName
            )
        } catch let error as TmuxSessionMutationError {
            throw terminalOperationError(error)
        }

        await tmuxSessionDiscovery.recordTermination(
            target: tab.target,
            sessionNames: [sessionName]
        )
        closeTabs(target: tab.target, sessionNames: [sessionName])
    }

    func terminateTmuxSessions(
        _ sessionNames: Set<String>,
        target: TerminalTarget
    ) async -> TmuxBatchTerminationResult {
        let validNames = Set(
            sessionNames.filter(TmuxSessionParser.isAttachable)
        )
        let invalidNames = sessionNames.subtracting(validNames)
        let controller = tmuxSessionController
        let results = await withTaskGroup(
            of: (String, Bool).self
        ) { group -> [(String, Bool)] in
            for sessionName in validNames {
                group.addTask {
                    do {
                        try await controller.terminate(
                            target: target,
                            sessionName: sessionName
                        )
                        return (sessionName, true)
                    } catch {
                        return (sessionName, false)
                    }
                }
            }

            var results: [(String, Bool)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let succeeded = Set(results.compactMap { $0.1 ? $0.0 : nil })
        let failed = Set(results.compactMap { $0.1 ? nil : $0.0 })
            .union(invalidNames)
        await tmuxSessionDiscovery.recordTermination(
            target: target,
            sessionNames: succeeded
        )
        closeTabs(target: target, sessionNames: succeeded)
        return TmuxBatchTerminationResult(
            succeeded: succeeded,
            failed: failed
        )
    }

    func openInTerminal(_ id: String) async throws {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        if MerlinCommands.sshConnectionTarget(for: tab.target) != nil {
            switch await tmuxSessionDiscovery.retryAttachment(target: tab.target) {
            case .ready:
                break
            case .sshUnavailable:
                throw TerminalTabOperationError.sshUnavailable
            case .workerNotReady:
                throw TerminalTabOperationError.workerNotReady
            case .tmuxUnavailable:
                throw TerminalTabOperationError.tmuxUnavailable
            }
        }
        try await externalTerminalLauncher.open(
            command(for: tab, destination: .externalTerminal)
        )
    }

    func openPlainSSHInTerminal(_ id: String) async throws {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            let alias = MerlinCommands.sshConnectionTarget(for: tab.target)
        else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        guard await runtime.sshMasterPool.prepare(
            alias: alias,
            priority: .foreground
        ) == .ready else {
            throw TerminalTabOperationError.sshUnavailable
        }
        try await externalTerminalLauncher.open(
            managedTerminalCommands.plainSSHCommand(target: tab.target)
        )
    }

    private func requestTmuxCreation(
        title: String,
        target: TerminalTarget,
        sessionName: String
    ) {
        tmuxCreation.request(TmuxCreationDraft(
            title: title,
            target: target,
            suggestedSessionName: sessionName
        ))
    }

    private func open(
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        workingDirectory: String? = nil
    ) {
        let id = UUID().uuidString
        let record = TerminalTabRecord(
            id: id,
            title: title,
            target: target,
            sessionName: sessionName,
            workingDirectory: workingDirectory
        )
        tabs.append(record)
        selectedTabID = id
        _ = session(for: id)
        persist()
    }

    private enum CommandDestination {
        case swiftTerm
        case externalTerminal
    }

    private func command(
        for tab: TerminalTabRecord,
        destination: CommandDestination
    ) throws -> CommandSpec {
        switch tab.target {
        case .local:
            if let sessionName = tab.sessionName {
                guard let tmux = resolvedLocalTmuxPath() else {
                    throw CommandValidationError.invalidExecutablePath
                }
                return try MerlinCommands.localTerminal(
                    tmuxPath: tmux,
                    sessionName: sessionName,
                    workingDirectory: tab.workingDirectory
                )
            }
            let configuredShell = ProcessInfo.processInfo.environment["SHELL"]
            let shell = configuredShell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            return CommandSpec(executable: shell, arguments: ["-l"])
        case .devbox, .worker:
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            switch destination {
            case .swiftTerm:
                return try managedTerminalCommands.swiftTermCommand(
                    target: tab.target,
                    sessionName: sessionName,
                    workingDirectory: tab.workingDirectory
                )
            case .externalTerminal:
                return try managedTerminalCommands.externalTerminalCommand(
                    target: tab.target,
                    sessionName: sessionName,
                    workingDirectory: tab.workingDirectory
                )
            }
        }
    }

    private func makeSessionName(label: String) -> String {
        let safeLabel = label
            .lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) ? $0 : "-" }
        let compactLabel = String(String(safeLabel).prefix(36)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "mlz-\(compactLabel.isEmpty ? "shell" : compactLabel)-\(suffix)"
    }

    private func closeTabs(
        target: TerminalTarget,
        sessionNames: Set<String>
    ) {
        let matchingIDs: [String] = tabs.compactMap { tab -> String? in
            guard
                tab.target.identity == target.identity,
                let sessionName = tab.sessionName,
                sessionNames.contains(sessionName)
            else {
                return nil
            }
            return tab.id
        }
        for id in matchingIDs {
            close(id)
        }
    }

    private func terminalOperationError(
        _ error: TmuxSessionMutationError
    ) -> TerminalTabOperationError {
        switch error {
        case .localTmuxNotFound:
            .localTmuxNotFound
        case .workerNotReady:
            .workerNotReady
        case let .commandFailed(exitCode):
            .commandFailed(exitCode: exitCode)
        }
    }

    private func resolvedLocalTmuxPath() -> String? {
        [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func persist() {
        let state = TerminalState(selectedTabID: selectedTabID, tabs: tabs)
        if let encoded = try? TerminalStateCodec.encode(state) {
            defaults.set(encoded, forKey: persistenceKey)
        }
    }

    private func seedWarmupPriorities() {
        var desiredTargets: [TerminalTarget] = []
        if let selectedTab {
            desiredTargets.append(selectedTab.target)
        }
        for tab in tabs.reversed()
        where !desiredTargets.contains(tab.target)
        {
            desiredTargets.append(tab.target)
        }
        for target in desiredTargets.reversed() {
            runtime.prioritize(target)
        }
    }
}

struct TmuxBatchTerminationResult: Sendable {
    let succeeded: Set<String>
    let failed: Set<String>
}

enum TerminalTabOperationError: LocalizedError {
    case invalidSessionName
    case invalidWorkingDirectory
    case sessionUnavailable
    case localTmuxNotFound
    case workerNotReady
    case sshUnavailable
    case tmuxUnavailable
    case commandFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSessionName:
            "tmux 会话名只能包含字母、数字、点、短横线和下划线，且最长 64 个字符。"
        case .invalidWorkingDirectory:
            "工作目录必须是绝对路径，不能包含换行或空字符，且最长 1024 个字符。"
        case .sessionUnavailable:
            "这个标签没有可操作的 tmux 会话。"
        case .localTmuxNotFound:
            "本机未找到 tmux。"
        case .workerNotReady:
            "工作机尚未就绪，暂时无法操作 tmux 会话。"
        case .sshUnavailable:
            "SSH 连接不可用，请检查认证或网络后重试。"
        case .tmuxUnavailable:
            "SSH 可用，但 tmux 未在限定时间内响应。已停止连接，避免继续堆积客户端。"
        case let .commandFailed(exitCode):
            "tmux 操作失败（退出码 \(exitCode)）。"
        }
    }
}
