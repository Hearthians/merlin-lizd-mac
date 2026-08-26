import Foundation
import SSHTmuxHubCore
import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject, TerminalTabTmuxStateStoring {
    @Published private(set) var tabs: [TerminalTabRecord]
    @Published var selectedTabID: String? {
        didSet {
            persist()
            guard let selectedTab else { return }
            runtime.prepare(selectedTab.target)
        }
    }

    private var sessions: [String: TerminalSession] = [:]
    private let defaults: UserDefaults
    private let managedTerminalCommands: ManagedTerminalCommandBuilder
    private let runtime: HubRuntime
    let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionController: TmuxSessionController
    private let externalTerminalLauncher = ExternalTerminalLauncher()
    private let persistenceKey = "terminal-state-v2"

    init(runtime: HubRuntime, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.defaults = defaults
        managedTerminalCommands = ManagedTerminalCommandBuilder(
            sshMasterPool: runtime.sshMasterPool
        )
        tmuxSessionDiscovery = runtime.tmuxDiscovery
        tmuxSessionController = runtime.tmuxController

        if let encoded = defaults.string(forKey: persistenceKey),
            let restored = try? TerminalStateCodec.decode(encoded)
        {
            let validTabs = restored.tabs.filter(Self.isValidRestoredTab)
            tabs = validTabs
            selectedTabID = validTabs.contains(where: {
                $0.id == restored.selectedTabID
            }) ? restored.selectedTabID : nil
        } else {
            tabs = []
            selectedTabID = nil
        }
    }

    var selectedTab: TerminalTabRecord? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func openLocalShell() {
        open(title: "本机", target: .local, sessionName: nil)
    }

    func openLocalTmux(sessionName: String? = nil) {
        let name = sessionName ?? makeSessionName(label: "local")
        guard TmuxSessionParser.isAttachable(name) else { return }
        open(title: "本机 · \(name)", target: .local, sessionName: name)
    }

    func openSSH(_ destination: String, sessionName: String? = nil) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        let name = sessionName ?? makeSessionName(label: destination)
        guard TmuxSessionParser.isAttachable(name) else { return }
        open(
            title: "\(destination) · \(name)",
            target: .ssh(destination: destination),
            sessionName: name
        )
    }

    func attachExistingSession(
        _ session: TmuxSessionRecord,
        target: TerminalTarget
    ) {
        guard TmuxSessionParser.isAttachable(session.name) else { return }
        let label = switch target {
        case .local: "本机"
        case let .ssh(destination): destination
        }
        open(
            title: "\(label) · \(session.name)",
            target: target,
            sessionName: session.name,
            tmuxIdentity: session.identity
        )
    }

    func knownTmuxSessions(for target: TerminalTarget) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return tabs.compactMap { tab in
            guard tab.target == target,
                let sessionName = tab.sessionName,
                TmuxSessionParser.isAttachable(sessionName),
                seen.insert(sessionName).inserted
            else {
                return nil
            }
            return TmuxSessionRecord(
                name: sessionName,
                identity: tab.tmuxIdentity
            )
        }
    }

    func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        if let existing = sessions[id] {
            if case .exited = existing.state { reconnect(id) }
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
        sessions.removeValue(forKey: id)?.close()
        _ = session(for: id)
        selectedTabID = id
        objectWillChange.send()
    }

    func session(for id: String) -> TerminalSession? {
        if let existing = sessions[id] { return existing }
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        do {
            let session = TerminalSession(
                id: UUID(uuidString: tab.id) ?? UUID(),
                command: try command(for: tab),
                currentDirectory: tab.target == .local
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : nil
            )
            sessions[id] = session
            return session
        } catch {
            return nil
        }
    }

    func sessionForRendering(_ id: String) -> TerminalSession? {
        if let existing = sessions[id] { return existing }
        guard selectedTabID == id else { return nil }
        return session(for: id)
    }

    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.close()
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)
        if wasSelected {
            selectedTabID = tabs.indices.contains(index)
                ? tabs[index].id
                : tabs.last?.id
        }
        persist()
    }

    func renameTab(_ id: String, to proposedTitle: String) {
        let title = String(
            proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(100)
        )
        guard !title.isEmpty,
            let index = tabs.firstIndex(where: { $0.id == id })
        else { return }
        tabs[index].title = title
        persist()
    }

    func renameTmuxSession(_ id: String, to proposedName: String) async throws {
        let newName = proposedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard TmuxSessionParser.isAttachable(newName) else {
            throw TerminalTabOperationError.invalidSessionName
        }
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
        } catch {
            throw TerminalTabOperationError.sessionUnavailable
        }
    }

    func terminateTmuxSessionAndClose(_ id: String) async throws {
        guard let tab = tabs.first(where: { $0.id == id }),
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
        let validNames = Set(sessionNames.filter(TmuxSessionParser.isAttachable))
        let invalidNames = sessionNames.subtracting(validNames)
        let controller = tmuxSessionController
        let results = await withTaskGroup(of: (String, Bool).self) { group in
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
            var values: [(String, Bool)] = []
            for await value in group { values.append(value) }
            return values
        }
        let succeeded = Set(results.compactMap { $0.1 ? $0.0 : nil })
        let failed = Set(results.compactMap { $0.1 ? nil : $0.0 })
            .union(invalidNames)
        await tmuxSessionDiscovery.recordTermination(
            target: target,
            sessionNames: succeeded
        )
        closeTabs(target: target, sessionNames: succeeded)
        return TmuxBatchTerminationResult(succeeded: succeeded, failed: failed)
    }

    func openInTerminal(_ id: String) async throws {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        try await externalTerminalLauncher.open(command(for: tab))
    }

    func terminalTabsSnapshot() -> [TerminalTabRecord] { tabs }

    func replaceTerminalTabs(_ tabs: [TerminalTabRecord]) {
        self.tabs = tabs
    }

    func persistTerminalTabs() { persist() }

    private func open(
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        tmuxIdentity: TmuxSessionIdentity? = nil
    ) {
        let id = UUID().uuidString
        tabs.append(TerminalTabRecord(
            id: id,
            title: title,
            target: target,
            sessionName: sessionName,
            tmuxIdentity: tmuxIdentity
        ))
        selectedTabID = id
        _ = session(for: id)
        persist()
    }

    private func command(for tab: TerminalTabRecord) throws -> CommandSpec {
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
            let shell = configuredShell.flatMap {
                $0.hasPrefix("/") ? $0 : nil
            } ?? "/bin/zsh"
            return CommandSpec(executable: shell, arguments: ["-l"])
        case .ssh:
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            return try managedTerminalCommands.swiftTermCommand(
                target: tab.target,
                sessionName: sessionName
            )
        }
    }

    private func makeSessionName(label: String) -> String {
        let normalized = label.lowercased().map { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || ".-_".contains(character))
                ? character : "-"
        }
        let compact = String(normalized.prefix(38))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        ).prefix(8).lowercased()
        return "hub-\(compact.isEmpty ? "shell" : compact)-\(suffix)"
    }

    private func closeTabs(
        target: TerminalTarget,
        sessionNames: Set<String>
    ) {
        let ids = tabs.compactMap { tab -> String? in
            guard tab.target == target,
                let name = tab.sessionName,
                sessionNames.contains(name)
            else { return nil }
            return tab.id
        }
        ids.forEach(close)
    }

    private func terminalOperationError(
        _ error: TmuxSessionMutationError
    ) -> TerminalTabOperationError {
        switch error {
        case .localTmuxNotFound: .localTmuxNotFound
        case let .commandFailed(exitCode): .commandFailed(exitCode: exitCode)
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
        if let encoded = try? TerminalStateCodec.encode(
            TerminalState(selectedTabID: selectedTabID, tabs: tabs)
        ) {
            defaults.set(encoded, forKey: persistenceKey)
        }
    }

    private static func isValidRestoredTab(_ tab: TerminalTabRecord) -> Bool {
        switch tab.target {
        case .local:
            return tab.sessionName.map(TmuxSessionParser.isAttachable) ?? true
        case let .ssh(destination):
            return IdentifierValidator.isSSHDestination(destination)
                && tab.sessionName.map(TmuxSessionParser.isAttachable) == true
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
    case commandFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSessionName:
            "tmux 会话名只能包含字母、数字、点、短横线和下划线，且最长 64 个字符。"
        case .sessionUnavailable:
            "这个标签没有可操作的 tmux 会话，或会话已被替换。"
        case .localTmuxNotFound:
            "本机未找到 tmux。请先通过 Homebrew 安装 tmux。"
        case let .commandFailed(exitCode):
            "tmux 操作失败（退出码 \(exitCode)）。"
        }
    }
}
