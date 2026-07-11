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

    func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        _ = session(for: id)
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
                let candidates = [
                    "/opt/homebrew/bin/tmux",
                    "/usr/local/bin/tmux",
                    "/usr/bin/tmux",
                ]
                guard let tmux = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
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

    private func persist() {
        let state = TerminalState(selectedTabID: selectedTabID, tabs: tabs)
        if let encoded = try? TerminalStateCodec.encode(state) {
            defaults.set(encoded, forKey: persistenceKey)
        }
    }
}
