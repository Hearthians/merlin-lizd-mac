import Foundation
import MerlinLizdCore
import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject {
    @Published private(set) var tabs: [TerminalTabRecord]
    @Published var selectedTabID: String? {
        didSet { persist() }
    }

    private var sessions: [String: TerminalSession] = [:]
    private let defaults: UserDefaults
    let tmuxSessionDiscovery = TmuxSessionDiscovery()
    private let tmuxSessionController = TmuxSessionController()
    private let externalTerminalLauncher = ExternalTerminalLauncher()
    private let persistenceKey = "terminal-state-v1"

    init(defaults: UserDefaults = .standard) {
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

    func attachExistingSession(_ sessionName: String, target: TerminalTarget) {
        guard TmuxSessionParser.isAttachable(sessionName) else { return }
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
            title: "\(targetLabel) · \(sessionName)",
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
            let command = try command(for: tab)
            let session = TerminalSession(
                id: UUID(uuidString: tab.id) ?? UUID(),
                command: command,
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
        guard
            let currentIndex = tabs.firstIndex(where: { $0.id == id }),
            tabs[currentIndex].sessionName == currentName
        else {
            return
        }
        tabs[currentIndex].sessionName = newName
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
        try await externalTerminalLauncher.open(command(for: tab))
    }

    private func open(title: String, target: TerminalTarget, sessionName: String?) {
        let id = UUID().uuidString
        let record = TerminalTabRecord(
            id: id,
            title: title,
            target: target,
            sessionName: sessionName
        )
        tabs.append(record)
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
            let shell = configuredShell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            return CommandSpec(executable: shell, arguments: ["-l"])
        case let .devbox(_, _, alias):
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            return try MerlinCommands.devboxTerminal(alias: alias, sessionName: sessionName)
        case let .worker(_, _, alias, workerID):
            guard let sessionName = tab.sessionName else {
                throw CommandValidationError.invalidSessionName
            }
            return try MerlinCommands.workerTerminal(
                alias: alias,
                workerID: workerID,
                sessionName: sessionName
            )
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
