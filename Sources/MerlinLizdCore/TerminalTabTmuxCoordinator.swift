import Foundation

@MainActor
public protocol TerminalTabTmuxStateStoring: AnyObject {
    func terminalTabsSnapshot() -> [TerminalTabRecord]
    func replaceTerminalTabs(_ tabs: [TerminalTabRecord])
    func persistTerminalTabs()
}

public enum TerminalTabTmuxCoordinationError: Error, Equatable, Sendable {
    case sessionUnavailable
}

@MainActor
public enum TerminalTabTmuxCoordinator {
    public static func resolveIdentity(
        for tabID: String,
        state: any TerminalTabTmuxStateStoring,
        discovery: TmuxSessionDiscovery
    ) async -> TmuxSessionIdentity? {
        let tabs = state.terminalTabsSnapshot()
        guard let current = tabs.first(where: { $0.id == tabID }) else {
            return nil
        }
        if let identity = current.tmuxIdentity {
            return identity
        }
        guard
            let sessionName = current.sessionName,
            TmuxSessionParser.isAttachable(sessionName)
        else {
            return nil
        }

        let snapshot = await discovery.refresh(
            target: current.target,
            lane: .foreground
        )
        guard snapshot.readiness == .ready, snapshot.lastError == nil else {
            return nil
        }
        let identities = Set(snapshot.sessions.compactMap { session in
            session.name == sessionName ? session.identity : nil
        })
        guard identities.count == 1, let identity = identities.first else {
            return nil
        }

        var latestTabs = state.terminalTabsSnapshot()
        guard
            let index = latestTabs.firstIndex(where: { $0.id == tabID }),
            latestTabs[index].target == current.target,
            latestTabs[index].sessionName == sessionName
        else {
            return nil
        }
        if let existing = latestTabs[index].tmuxIdentity {
            return existing
        }
        latestTabs[index].tmuxIdentity = identity
        state.replaceTerminalTabs(latestTabs)
        state.persistTerminalTabs()
        return identity
    }

    public static func rename(
        tabID: String,
        to newName: String,
        state: any TerminalTabTmuxStateStoring,
        controller: TmuxSessionController,
        discovery: TmuxSessionDiscovery
    ) async throws {
        let initialTabs = state.terminalTabsSnapshot()
        guard
            let initiatingTab = initialTabs.first(where: { $0.id == tabID }),
            let currentName = initiatingTab.sessionName
        else {
            throw TerminalTabTmuxCoordinationError.sessionUnavailable
        }

        try await controller.rename(
            target: initiatingTab.target,
            from: currentName,
            to: newName
        )
        await discovery.recordRename(
            target: initiatingTab.target,
            from: currentName,
            to: newName
        )

        var latestTabs = state.terminalTabsSnapshot()
        let initiatingIdentity = latestTabs.first(where: {
            $0.id == tabID
        })?.tmuxIdentity ?? initiatingTab.tmuxIdentity
        let stableTarget = TerminalTargetIdentity(initiatingTab.target)
        var changed = false

        for index in latestTabs.indices {
            let candidate = latestTabs[index]
            let matchesIdentity = initiatingIdentity != nil
                && TerminalTargetIdentity(candidate.target) == stableTarget
                && candidate.tmuxIdentity == initiatingIdentity
            let matchesLegacyName = candidate.tmuxIdentity == nil
                && candidate.target == initiatingTab.target
                && candidate.sessionName == currentName
            guard matchesIdentity || matchesLegacyName else { continue }
            latestTabs[index].sessionName = newName
            changed = true
        }

        if changed {
            state.replaceTerminalTabs(latestTabs)
            state.persistTerminalTabs()
        }
    }
}
