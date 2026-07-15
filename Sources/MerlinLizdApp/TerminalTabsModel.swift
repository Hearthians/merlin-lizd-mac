import Foundation
import MerlinLizdCore
import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject, TerminalTabTmuxStateStoring {
    @Published private(set) var tabs: [TerminalTabRecord]
    @Published var selectedTabID: String? {
        didSet {
            persist()
            focusSelectedCodexEndpoint()
            guard let selectedTab else { return }
            prioritize(selectedTab.target)
        }
    }

    private var sessions: [String: TerminalSession] = [:]
    private let defaults: UserDefaults
    private let managedTerminalCommands: ManagedTerminalCommandBuilder
    private let runtime: MerlinRemoteRuntime
    private let codexRuntime: CodexRuntime?
    private let codexFocusArbiter: TerminalEndpointFocusArbiter?
    let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionController: TmuxSessionController
    private let externalTerminalLauncher = ExternalTerminalLauncher()
    private let persistenceKey = "terminal-state-v1"
    private var codexEndpointTokens: [String: UUID] = [:]
    private var codexEndpointTasks: [String: Task<Void, Never>] = [:]
    private var codexEndpointIDs: [String: TerminalEndpointID] = [:]

    init(
        runtime: MerlinRemoteRuntime,
        codexRuntime: CodexRuntime?,
        defaults: UserDefaults = .standard
    ) {
        managedTerminalCommands = ManagedTerminalCommandBuilder(
            sshMasterPool: runtime.sshMasterPool
        )
        self.runtime = runtime
        self.codexRuntime = codexRuntime
        if let coordinator = codexRuntime?.coordinator {
            codexFocusArbiter = TerminalEndpointFocusArbiter { endpointID in
                try? await coordinator.focusEndpoint(endpointID)
            }
        } else {
            codexFocusArbiter = nil
        }
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
        codexRuntime?.startNotifications(
            foregroundConversation: { [weak self] in
                self?.selectedConversationKey
            },
            openConversation: { [weak self] key in
                self?.selectConversation(key)
            }
        )
    }

    var selectedTab: TerminalTabRecord? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func openLocal() {
        open(
            title: "本机",
            target: .local,
            sessionName: nil
        )
    }

    func openDevbox(_ machine: DevboxInventory) {
        guard let alias = machine.sshAlias else { return }
        open(
            title: alias,
            target: .devbox(
                sid: machine.devbox.sid,
                name: machine.devbox.name,
                alias: alias
            ),
            sessionName: makeSessionName(label: alias)
        )
    }

    func openWorker(_ worker: WorkerInventoryRecord, on machine: DevboxInventory) {
        guard let alias = machine.sshAlias else { return }
        open(
            title: "\(worker.gpuType ?? "Worker") · \(worker.id)",
            target: .worker(
                devboxSID: machine.devbox.sid,
                devboxName: machine.devbox.name,
                alias: alias,
                workerID: worker.id
            ),
            sessionName: makeSessionName(label: "\(alias)-\(worker.id)")
        )
    }

    func attachExistingSession(
        _ session: TmuxSessionRecord,
        target: TerminalTarget
    ) {
        guard TmuxSessionParser.isAttachable(session.name) else { return }
        let targetLabel: String
        switch target {
        case .local:
            targetLabel = "本机"
        case let .devbox(_, _, alias):
            targetLabel = alias
        case let .worker(_, _, _, workerID):
            targetLabel = "Worker \(workerID)"
        }
        open(
            title: "\(targetLabel) · \(session.name)",
            target: target,
            sessionName: session.name,
            tmuxIdentity: session.identity
        )
    }

    func knownTmuxSessions(for target: TerminalTarget) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return tabs.compactMap { tab in
            guard
                tab.target == target,
                let sessionName = tab.sessionName,
                TmuxSessionParser.isAttachable(sessionName)
            else {
                return nil
            }
            let session = TmuxSessionRecord(
                name: sessionName,
                identity: tab.tmuxIdentity
            )
            return seen.insert(session.id).inserted ? session : nil
        }
    }

    func resolveTmuxIdentity(
        for tab: TerminalTabRecord
    ) async -> TmuxSessionIdentity? {
        await TerminalTabTmuxCoordinator.resolveIdentity(
            for: tab.id,
            state: self,
            discovery: tmuxSessionDiscovery
        )
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
            case .idle, .running:
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

    func reconnect(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        detachCodexEndpoint(for: id)
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
            let session = TerminalSession(
                id: UUID(uuidString: tab.id) ?? UUID(),
                command: command,
                currentDirectory: tab.target == .local
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : nil
            )
            sessions[id] = session
            registerCodexEndpoint(for: tab, session: session)
            return session
        } catch {
            return nil
        }
    }

    func close(_ id: String) {
        detachCodexEndpoint(for: id)
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
            try await TerminalTabTmuxCoordinator.rename(
                tabID: id,
                to: newName,
                state: self,
                controller: tmuxSessionController,
                discovery: tmuxSessionDiscovery
            )
        } catch let error as TmuxSessionMutationError {
            throw terminalOperationError(error)
        } catch is TerminalTabTmuxCoordinationError {
            throw TerminalTabOperationError.sessionUnavailable
        }
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
        try await externalTerminalLauncher.open(
            command(for: tab, destination: .externalTerminal)
        )
    }

    private func open(
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        tmuxIdentity: TmuxSessionIdentity? = nil
    ) {
        let id = UUID().uuidString
        let record = TerminalTabRecord(
            id: id,
            title: title,
            target: target,
            sessionName: sessionName,
            tmuxIdentity: tmuxIdentity
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
                return CommandSpec(
                    executable: tmux,
                    arguments: ["new-session", "-A", "-s", sessionName]
                )
            }
            let configuredShell = ProcessInfo.processInfo.environment["SHELL"]
            let shell = configuredShell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            return CommandSpec(executable: shell, arguments: ["-l"])
        case .devbox:
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            switch destination {
            case .swiftTerm:
                return try managedTerminalCommands.swiftTermCommand(
                    target: tab.target, sessionName: sessionName
                )
            case .externalTerminal:
                return try managedTerminalCommands.externalTerminalCommand(
                    target: tab.target, sessionName: sessionName
                )
            }
        case .worker:
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            switch destination {
            case .swiftTerm:
                return try managedTerminalCommands.swiftTermCommand(
                    target: tab.target, sessionName: sessionName
                )
            case .externalTerminal:
                return try managedTerminalCommands.externalTerminalCommand(
                    target: tab.target, sessionName: sessionName
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
                tab.target == target,
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

    private var selectedConversationKey: TerminalConversationKey? {
        guard let selectedTab, let identity = selectedTab.tmuxIdentity else {
            return nil
        }
        return TerminalConversationKey(
            terminalTarget: selectedTab.target,
            tmux: identity
        )
    }

    private func registerCodexEndpoint(
        for tab: TerminalTabRecord,
        session: TerminalSession
    ) {
        guard let codexRuntime, tab.sessionName != nil else { return }
        let token = UUID()
        codexEndpointTokens[tab.id] = token
        codexEndpointTasks[tab.id]?.cancel()
        codexEndpointTasks[tab.id] = Task { [weak self, weak session] in
            guard let self else { return }
            defer {
                if self.codexEndpointTokens[tab.id] == token {
                    self.codexEndpointTasks.removeValue(forKey: tab.id)
                }
            }
            guard let session,
                let identity = await self.resolveTmuxIdentity(for: tab)
            else { return }
            await self.finishCodexEndpointRegistration(
                tabID: tab.id,
                token: token,
                identity: identity,
                session: session,
                coordinator: codexRuntime.coordinator,
                surfaces: codexRuntime.tmuxController
            )
        }
    }

    private func finishCodexEndpointRegistration(
        tabID: String,
        token: UUID,
        identity: TmuxSessionIdentity,
        session: TerminalSession,
        coordinator: CodexSessionCoordinator,
        surfaces: TmuxSessionController
    ) async {
        guard codexEndpointTokens[tabID] == token,
            sessions[tabID] === session,
            let currentTab = tabs.first(where: { $0.id == tabID }),
            currentTab.tmuxIdentity == identity,
            let sessionName = currentTab.sessionName
        else { return }

        let endpointID = TerminalEndpointID(rawValue: UUID())
        let endpoint = TerminalEndpoint(
            id: endpointID,
            conversationKey: TerminalConversationKey(
                terminalTarget: currentTab.target,
                tmux: identity
            ),
            terminal: session.terminalDriver,
            surfaces: surfaces,
            route: TmuxRoute(
                target: currentTab.target,
                sessionName: sessionName,
                expectedIdentity: identity
            )
        )
        do {
            try await coordinator.registerEndpoint(endpoint)
        } catch {
            return
        }
        guard codexEndpointTokens[tabID] == token,
            sessions[tabID] === session
        else {
            await coordinator.unregisterEndpoint(endpointID)
            return
        }
        codexEndpointIDs[tabID] = endpointID
        if selectedTabID == tabID {
            await codexFocusArbiter?.requestFocus(endpointID)
        }
    }

    private func detachCodexEndpoint(for tabID: String) {
        codexEndpointTokens.removeValue(forKey: tabID)
        codexEndpointTasks.removeValue(forKey: tabID)?.cancel()
        guard let endpointID = codexEndpointIDs.removeValue(forKey: tabID),
            let coordinator = codexRuntime?.coordinator
        else { return }
        Task { await coordinator.unregisterEndpoint(endpointID) }
    }

    private func focusSelectedCodexEndpoint() {
        guard let selectedTabID,
            let endpointID = codexEndpointIDs[selectedTabID],
            let codexFocusArbiter
        else { return }
        Task { await codexFocusArbiter.requestFocus(endpointID) }
    }

    private func selectConversation(_ key: TerminalConversationKey) {
        guard let tab = tabs.first(where: { tab in
            guard let identity = tab.tmuxIdentity else { return false }
            return TerminalConversationKey(
                terminalTarget: tab.target,
                tmux: identity
            ) == key
        }) else { return }
        select(tab.id)
    }

    func terminalTabsSnapshot() -> [TerminalTabRecord] {
        tabs
    }

    func replaceTerminalTabs(_ tabs: [TerminalTabRecord]) {
        self.tabs = tabs
    }

    func persistTerminalTabs() {
        persist()
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
    case sessionUnavailable
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSessionName:
            "tmux 会话名只能包含字母、数字、点、短横线和下划线，且最长 64 个字符。"
        case .sessionUnavailable:
            "这个标签没有可操作的 tmux 会话。"
        case .localTmuxNotFound:
            "本机未找到 tmux。"
        case .workerNotReady:
            "工作机尚未就绪，暂时无法操作 tmux 会话。"
        case let .commandFailed(exitCode):
            "tmux 操作失败（退出码 \(exitCode)）。"
        }
    }
}
