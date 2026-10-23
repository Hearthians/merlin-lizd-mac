import AppKit
import Foundation
import TmuxHubCore
import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject, TerminalTabTmuxStateStoring {
    @Published private(set) var tabs: [TerminalTabRecord]
    @Published private(set) var tmuxConfigurationStates: [TerminalTarget: TmuxConfigurationState] = [:]
    @Published private(set) var vimPasteConfigurationStates: [TerminalTarget: VimPasteConfigurationState] = [:]
    @Published private(set) var remoteEditorInstalling: Set<String> = []
    @Published private(set) var remoteEditorMessages: [String: String] = [:]
    @Published var notificationOpenError: String?
    @Published var selectedTabID: String? {
        didSet {
            if oldValue != selectedTabID {
                for (id, session) in sessions { session.isSelected = id == selectedTabID }
            }
            persist()
            guard let selectedTab else { return }
            prepareForUse(selectedTab.target, notificationRoute: selectedTab.notificationRoute)
        }
    }

    private var sessions: [String: TerminalSession] = [:]
    private var attachments: [String: TerminalAttachmentModel] = [:]
    private var notificationOpenTask: Task<Void, Never>?
    private var notificationOpenToken: UUID?
    private let defaults: UserDefaults
    private let managedTerminalCommands: ManagedTerminalCommandBuilder
    private let runtime: HubRuntime
    let tmuxSessionDiscovery: TmuxSessionDiscovery
    var herdrService: HerdrService { runtime.herdrService }
    var remoteFileService: RemoteFileService { RemoteFileService(pool: runtime.sshMasterPool) }
    private let tmuxSessionController: TmuxSessionController
    private let externalTerminalLauncher = ExternalTerminalLauncher()
    private let persistenceKey = "terminal-state-v2"
    private let onRemoteHostUsed: (String, Date) -> Void

    init(
        runtime: HubRuntime,
        defaults: UserDefaults = .standard,
        onRemoteHostUsed: @escaping (String, Date) -> Void = { _, _ in }
    ) {
        self.runtime = runtime
        self.defaults = defaults
        self.onRemoteHostUsed = onRemoteHostUsed
        managedTerminalCommands = ManagedTerminalCommandBuilder(
            sshMasterPool: runtime.sshMasterPool
        )
        tmuxSessionDiscovery = runtime.tmuxDiscovery
        tmuxSessionController = runtime.tmuxController

        if let encoded = defaults.string(forKey: persistenceKey),
            let restored = try? TerminalStateCodec.decode(encoded)
        {
            let validTabs = restored.tabs.compactMap { tab -> TerminalTabRecord? in
                guard let normalized = Self.normalizedRestoredTab(tab) else { return nil }
                TerminalAttachmentModel.migrateDirectoryOverride(
                    target: tab.target, from: tab.sessionName,
                    to: normalized.sessionName, defaults: defaults
                )
                return normalized
            }
            tabs = validTabs
            selectedTabID = validTabs.contains(where: {
                $0.id == restored.selectedTabID
            }) ? restored.selectedTabID : nil
            if validTabs != restored.tabs { persist() }
        } else {
            tabs = []
            selectedTabID = nil
        }
    }

    var selectedTab: TerminalTabRecord? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func repairVimPaste(on target: TerminalTarget) async {
        guard vimPasteConfigurationStates[target] != .applying else { return }
        vimPasteConfigurationStates[target] = .applying
        do {
            let result = try await tmuxSessionController.applyVimPasteConfiguration(target: target)
            vimPasteConfigurationStates[target] = .applied(result)
        } catch let TmuxSessionMutationError.commandFailed(exitCode) {
            vimPasteConfigurationStates[target] = .failed(
                VimPasteConfigurationError.commandFailed(exitCode: exitCode, detail: "").localizedDescription
            )
        } catch {
            vimPasteConfigurationStates[target] = .failed(error.localizedDescription)
        }
    }

    func installRemoteEditor(on destination: String) async {
        guard IdentifierValidator.isSSHDestination(destination),
            !remoteEditorInstalling.contains(destination) else { return }
        remoteEditorInstalling.insert(destination)
        remoteEditorMessages[destination] = nil
        defer { remoteEditorInstalling.remove(destination) }
        do {
            try await RemoteEditorInstallation.install(destination: destination, pool: runtime.sshMasterPool)
            remoteEditorMessages[destination] = "已启用。重新连接标签页后，新 shell 可直接使用 code .；已有 shell 请加载下面的配置。"
        } catch {
            remoteEditorMessages[destination] = error.localizedDescription
        }
    }

    func openLocalShell() {
        open(title: "本机", target: .local, sessionName: nil)
    }

    func openCodexNotification(_ entry: CodexNotificationEntry) {
        notificationOpenError = nil
        notificationOpenTask?.cancel()
        let token = UUID()
        notificationOpenToken = token
        notificationOpenTask = Task { [weak self] in
            await self?.performOpenCodexNotification(entry, token: token)
        }
    }

    private func performOpenCodexNotification(_ entry: CodexNotificationEntry, token: UUID) async {
        do {
            if entry.destination == nil,
                let url = await CodexDesktopNotificationResolver.resolve(event: entry.event) {
                try Task.checkCancellation()
                guard notificationOpenToken == token else { return }
                guard NSWorkspace.shared.open(url) else {
                    throw NotificationSessionOpenError.desktopUnavailable
                }
                return
            }
            guard let originalRoute = try? CodexNotificationRoute(event: entry.event) else {
                throw NotificationSessionOpenError.missingRoute
            }
            let target = entry.destination.map { TerminalTarget.ssh(destination: $0) } ?? .local
            let route = try await CodexNotificationRouting.resolveAndFocus(route: originalRoute, target: target,
                sshMasterPool: runtime.sshMasterPool)
            try Task.checkCancellation()
            guard notificationOpenToken == token else { return }
            if let index = tabs.firstIndex(where: {
                $0.target == target && $0.notificationRoute?.isSameSession(as: route) == true
            }) {
                tabs[index].notificationRoute = route
                attachments[tabs[index].id]?.notificationRoute = route
                // The live tmux client may have switched sessions since the
                // previous click. Reattach this client to the verified route.
                reconnect(tabs[index].id)
                persist()
            } else {
                open(title: "\(entry.destination ?? "本机") · \(entry.event.tmuxSession ?? "Codex")",
                    target: target, sessionName: entry.event.tmuxSession,
                    tmuxLaunchMode: .attachOnly, notificationRoute: route)
            }
        } catch {
            if !Task.isCancelled, notificationOpenToken == token {
                notificationOpenError = error.localizedDescription
            }
        }
    }

    func openLocalTmux(sessionName: String? = nil) {
        guard let name = IdentifierValidator.normalizedTmuxSessionName(
            sessionName ?? makeSessionName(label: "local")
        ) else { return }
        open(
            title: "本机 · \(name)",
            target: .local,
            sessionName: name,
            tmuxLaunchMode: Self.isPlatformManagedTmuxSessionName(name)
                ? .attachOnly : .createOrAttach
        )
    }

    func openSSH(_ destination: String, sessionName: String? = nil) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        guard let name = IdentifierValidator.normalizedTmuxSessionName(
            sessionName ?? makeSessionName(label: destination)
        ) else { return }
        open(
            title: "\(destination) · \(name)",
            target: .ssh(destination: destination),
            sessionName: name,
            tmuxLaunchMode: Self.isPlatformManagedTmuxSessionName(name)
                ? .attachOnly : .createOrAttach
        )
    }

    func openAttachOnlyRemoteTmux(
        destination: String,
        sessionName: String,
        title: String? = nil,
        tmuxIdentity: TmuxSessionIdentity? = nil
    ) {
        guard IdentifierValidator.isSSHDestination(destination),
            let name = IdentifierValidator.normalizedTmuxSessionName(sessionName)
        else { return }
        let target = TerminalTarget.ssh(destination: destination)
        if let index = tabs.lastIndex(where: {
            $0.target == target && $0.sessionName == name
        }) {
            tabs[index].tmuxLaunchMode = .attachOnly
            if let tmuxIdentity { tabs[index].tmuxIdentity = tmuxIdentity }
            persist()
            select(tabs[index].id)
            return
        }
        open(
            title: title ?? "\(destination) · \(name)",
            target: target,
            sessionName: name,
            tmuxIdentity: tmuxIdentity,
            tmuxLaunchMode: .attachOnly
        )
    }

    func openOrResumeSSH(_ destination: String) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        let target = TerminalTarget.ssh(destination: destination)
        if let existing = tabs.last(where: {
            $0.target == target
                && $0.herdrReference == nil
                && allowsTmuxLifecycleMutation($0)
        }) {
            select(existing.id)
            return
        }
        guard let stableName = IdentifierValidator.stableTmuxSessionName(
            for: destination
        ) else { return }
        openSSH(destination, sessionName: stableName)
    }

    func openHerdr(_ pane: HerdrPaneRecord, target: TerminalTarget, workspaceLabel: String) {
        if let existing = tabs.first(where: {
            $0.target == target && $0.herdrReference == pane.reference
        }) {
            select(existing.id)
            return
        }
        let host = target.sshDestination ?? "本机"
        open(
            title: "\(host) · \(workspaceLabel) · \(pane.agent ?? pane.label)",
            target: target, sessionName: nil, herdrReference: pane.reference
        )
    }

    func hasSavedPassword(for destination: String) async throws -> Bool {
        try await runtime.hasSavedPassword(for: destination)
    }

    func savePassword(_ password: String, for destination: String) async throws {
        try await runtime.savePassword(password, for: destination)
        prepareForUse(.ssh(destination: destination))
    }

    func authorizeSavedPassword(for destination: String) async throws {
        try await runtime.authorizeSavedPassword(for: destination)
    }

    func removePassword(for destination: String) async throws {
        try await runtime.removePassword(for: destination)
    }

    func applyTmuxConfiguration(to target: TerminalTarget) async {
        guard tmuxConfigurationStates[target] != .applying else { return }
        tmuxConfigurationStates[target] = .applying
        do {
            let result = try await tmuxSessionController.applyConfiguration(target: target)
            tmuxConfigurationStates[target] = .applied(result)
            if let destination = target.sshDestination { noteHostUse(destination) }
        } catch let TmuxSessionMutationError.commandFailed(exitCode) {
            tmuxConfigurationStates[target] = .failed(
                "无法完成主机连接（退出码 \(exitCode)），请检查 SSH 认证及网络后重试。"
            )
        } catch {
            tmuxConfigurationStates[target] = .failed(error.localizedDescription)
        }
    }

    func noteHostUse(_ destination: String, at date: Date = Date()) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        onRemoteHostUsed(destination, date)
    }

    func attachExistingSession(
        _ session: TmuxSessionRecord,
        target: TerminalTarget
    ) {
        guard let name = IdentifierValidator.normalizedTmuxSessionName(session.name) else {
            return
        }
        let label = switch target {
        case .local: "本机"
        case let .ssh(destination): destination
        }
        let externallyManaged = isTmuxSessionManagedExternally(
            sessionName: name,
            target: target
        )
        if externallyManaged,
            let index = tabs.lastIndex(where: {
                $0.target == target && $0.sessionName == name
            })
        {
            tabs[index].tmuxLaunchMode = .attachOnly
            tabs[index].tmuxIdentity = session.identity
            persist()
            select(tabs[index].id)
            return
        }
        open(
            title: "\(label) · \(name)",
            target: target,
            sessionName: name,
            tmuxIdentity: session.identity,
            tmuxLaunchMode: externallyManaged ? .attachOnly : .createOrAttach
        )
    }

    func isTmuxSessionManagedExternally(
        sessionName: String,
        target: TerminalTarget
    ) -> Bool {
        Self.isPlatformManagedTmuxSessionName(sessionName)
            || tabs.contains {
                $0.target == target
                    && $0.sessionName == sessionName
                    && $0.tmuxLaunchMode == .attachOnly
            }
    }

    func allowsTmuxLifecycleMutation(_ tab: TerminalTabRecord) -> Bool {
        tab.allowsTmuxLifecycleMutation
            && !Self.isPlatformManagedTmuxSessionName(tab.sessionName)
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
            // Restored tabs do not pass through selectedTabID's didSet during
            // initialization, so start their password-aware master preparation
            // here without delaying construction of the interactive terminal.
            prepareForUse(tab.target, notificationRoute: tab.notificationRoute)
            let attachmentModel = attachments[id] ?? TerminalAttachmentModel(
                target: tab.target, sessionName: tab.sessionName,
                service: runtime.attachmentService, defaults: defaults,
                herdrReference: tab.herdrReference,
                notificationRoute: tab.notificationRoute
            )
            attachments[id] = attachmentModel
            let session = TerminalSession(
                id: UUID(uuidString: tab.id) ?? UUID(),
                command: try command(for: tab),
                attachmentModel: attachmentModel,
                service: runtime.attachmentService,
                forwardedLinks: runtime.forwardedLinks,
                currentDirectory: tab.target == .local
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : nil
            )
            session.isSelected = selectedTabID == id
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
        attachments.removeValue(forKey: id)?.cancelAll()
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

    /// Bulk closing only disconnects tabs; it never terminates remote sessions.
    func closeOtherTabs(keeping id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let ids = tabs.filter { $0.id != id }.map(\.id)
        selectedTabID = id
        ids.forEach(close)
    }

    func closeAllTabs() {
        let ids = tabs.map(\.id)
        selectedTabID = nil
        ids.forEach(close)
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
        guard let tab = tabs.first(where: { $0.id == id }) else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        guard allowsTmuxLifecycleMutation(tab) else {
            throw TerminalTabOperationError.externallyManagedSession
        }
        let trimmedName = proposedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let newName = IdentifierValidator.normalizedTmuxSessionName(trimmedName) else {
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
        guard let tab = tabs.first(where: { $0.id == id }) else {
            throw TerminalTabOperationError.sessionUnavailable
        }
        guard allowsTmuxLifecycleMutation(tab) else {
            throw TerminalTabOperationError.externallyManagedSession
        }
        guard let sessionName = tab.sessionName else {
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
        let attachableNames = Set(sessionNames.filter(TmuxSessionParser.isAttachable))
        let protectedNames = Set(attachableNames.filter {
            isTmuxSessionManagedExternally(sessionName: $0, target: target)
        })
        let validNames = attachableNames.subtracting(protectedNames)
        let invalidNames = sessionNames.subtracting(attachableNames)
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
            .union(protectedNames)
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
        for tab in tabs {
            if let model = attachments[tab.id], model.sessionName != tab.sessionName {
                model.noteInteraction()
                model.sessionName = tab.sessionName
            }
        }
        self.tabs = tabs
    }

    func cancelAllAttachments() {
        notificationOpenTask?.cancel()
        notificationOpenToken = nil
        for model in attachments.values { model.cancelAll() }
    }

    func persistTerminalTabs() { persist() }

    private func open(
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        tmuxIdentity: TmuxSessionIdentity? = nil,
        herdrReference: HerdrTerminalReference? = nil,
        tmuxLaunchMode: TmuxSessionLaunchMode = .createOrAttach,
        notificationRoute: CodexNotificationRoute? = nil
    ) {
        let id = UUID().uuidString
        tabs.append(TerminalTabRecord(
            id: id,
            title: title,
            target: target,
            sessionName: sessionName,
            tmuxIdentity: tmuxIdentity,
            herdrReference: herdrReference,
            tmuxLaunchMode: tmuxLaunchMode,
            notificationRoute: notificationRoute
        ))
        selectedTabID = id
        _ = session(for: id)
        persist()
    }

    private func prepareForUse(_ target: TerminalTarget, notificationRoute: CodexNotificationRoute? = nil) {
        if let notificationRoute, let destination = target.sshDestination {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await CodexNotificationRouting.prepare(route: notificationRoute, target: target,
                        sshMasterPool: runtime.sshMasterPool)
                    noteHostUse(destination)
                } catch {
                    // The interactive terminal displays its own connection failure.
                }
            }
        } else {
            runtime.prepare(target) { [weak self] destination in
                self?.noteHostUse(destination)
            }
        }
    }

    private func command(for tab: TerminalTabRecord) throws -> CommandSpec {
        if let route = tab.notificationRoute {
            return try CodexNotificationRouting.managedAttachCommand(route: route, target: tab.target,
                sshMasterPool: runtime.sshMasterPool)
        }
        if let reference = tab.herdrReference {
            let command = try HerdrCommands.attach(target: tab.target, reference: reference)
            if let destination = tab.target.sshDestination {
                return try runtime.sshMasterPool.managedCommand(command, alias: destination)
            }
            return command
        }
        switch tab.target {
        case .local:
            if let sessionName = tab.sessionName {
                guard let tmux = resolvedLocalTmuxPath() else {
                    throw CommandValidationError.invalidExecutablePath
                }
                let arguments: [String] = switch tab.tmuxLaunchMode {
                case .createOrAttach:
                    ["new-session", "-A", "-s", sessionName]
                case .attachOnly:
                    ["attach-session", "-t", "=\(sessionName)"]
                }
                return CommandSpec(
                    executable: tmux,
                    arguments: arguments
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
                sessionName: sessionName,
                launchMode: tab.tmuxLaunchMode
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
        if let route = tab.notificationRoute {
            return route.isValid && tab.herdrReference == nil && tab.tmuxLaunchMode == .attachOnly
                && (tab.target.sshDestination.map(IdentifierValidator.isSSHDestination) ?? true)
        }
        if let reference = tab.herdrReference {
            guard tab.sessionName == nil, tab.tmuxIdentity == nil,
                tab.tmuxLaunchMode == .createOrAttach,
                reference.isValid else { return false }
            return tab.target.sshDestination.map(IdentifierValidator.isSSHDestination) ?? true
        }
        if tab.tmuxLaunchMode == .attachOnly, tab.sessionName == nil { return false }
        switch tab.target {
        case .local:
            return tab.sessionName.map(TmuxSessionParser.isAttachable) ?? true
        case let .ssh(destination):
            return IdentifierValidator.isSSHDestination(destination)
                && tab.sessionName.map(TmuxSessionParser.isAttachable) == true
        }
    }

    private static func normalizedRestoredTab(_ tab: TerminalTabRecord) -> TerminalTabRecord? {
        guard isValidRestoredTab(tab) else { return nil }
        var restored = tab
        if tab.notificationRoute != nil { return restored }
        restored.sessionName = tab.sessionName.flatMap(
            IdentifierValidator.normalizedTmuxSessionName
        )
        if isPlatformManagedTmuxSessionName(restored.sessionName) {
            restored.tmuxLaunchMode = .attachOnly
        }
        return restored
    }

    private static func isPlatformManagedTmuxSessionName(_ sessionName: String?) -> Bool {
        sessionName?.hasPrefix("tmuxhub-slurm-") == true
    }
}

private enum NotificationSessionOpenError: LocalizedError {
    case desktopUnavailable
    case missingRoute

    var errorDescription: String? {
        switch self {
        case .desktopUnavailable:
            "无法打开 Codex 桌面应用。请确认已安装 Codex，并能打开对应对话。"
        case .missingRoute:
            "这条通知没有记录可验证的原会话位置。请更新此来源的通知配置；新通知会记录 Codex 对话或 tmux 终端位置。旧通知若缺少这些信息，无法安全自动返回。"
        }
    }
}

enum TmuxConfigurationState: Equatable {
    case applying
    case applied(TmuxConfigurationResult)
    case failed(String)
}

enum VimPasteConfigurationState: Equatable {
    case applying
    case applied(VimPasteConfigurationResult)
    case failed(String)
}

struct TmuxBatchTerminationResult: Sendable {
    let succeeded: Set<String>
    let failed: Set<String>
}

enum TerminalTabOperationError: LocalizedError {
    case invalidSessionName
    case sessionUnavailable
    case localTmuxNotFound
    case externallyManagedSession
    case commandFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSessionName:
            "tmux 会话名只能包含字母、数字、点、短横线和下划线，且最长 64 个字符。"
        case .sessionUnavailable:
            "这个标签没有可操作的 tmux 会话，或会话已被替换。"
        case .localTmuxNotFound:
            "本机未找到 tmux。请先通过 Homebrew 安装 tmux。"
        case .externallyManagedSession:
            "这个 tmux 会话由外部任务管理，请从对应任务中停止或修改它。"
        case let .commandFailed(exitCode):
            "tmux 操作失败（退出码 \(exitCode)）。"
        }
    }
}
