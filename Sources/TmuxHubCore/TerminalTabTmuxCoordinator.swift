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

        // Capture provenance before mutation. The same identity selects the
        // remote session, scopes cache replay, and drives tab propagation.
        let observedIdentity = await probeIdentity(
            named: currentName,
            target: initiatingTab.target,
            discovery: discovery
        )
        var preMutationTabs = state.terminalTabsSnapshot()
        guard
            let preMutationIndex = preMutationTabs.firstIndex(where: {
                $0.id == tabID
            }),
            preMutationTabs[preMutationIndex].target == initiatingTab.target,
            preMutationTabs[preMutationIndex].sessionName == currentName
        else {
            throw TerminalTabTmuxCoordinationError.sessionUnavailable
        }
        let storedIdentity = preMutationTabs[preMutationIndex].tmuxIdentity
        if let storedIdentity, let observedIdentity,
            storedIdentity != observedIdentity
        {
            throw TerminalTabTmuxCoordinationError.sessionUnavailable
        }
        let renamedIdentity = observedIdentity ?? storedIdentity
        if preMutationTabs[preMutationIndex].tmuxIdentity == nil,
            let renamedIdentity
        {
            preMutationTabs[preMutationIndex].tmuxIdentity = renamedIdentity
            state.replaceTerminalTabs(preMutationTabs)
            state.persistTerminalTabs()
        }

        try await controller.rename(
            target: initiatingTab.target,
            from: currentName,
            to: newName,
            identity: renamedIdentity
        )
        await discovery.recordRename(
            target: initiatingTab.target,
            from: currentName,
            to: newName,
            identity: renamedIdentity
        )

        var latestTabs = state.terminalTabsSnapshot()
        var changed = false

        for index in latestTabs.indices {
            let candidate = latestTabs[index]
            let matchesIdentity = renamedIdentity != nil
                && candidate.target == initiatingTab.target
                && candidate.tmuxIdentity == renamedIdentity
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

    private static func probeIdentity(
        named sessionName: String,
        target: TerminalTarget,
        discovery: TmuxSessionDiscovery
    ) async -> TmuxSessionIdentity? {
        let snapshot = await discovery.refresh(
            target: target,
            lane: .foreground
        )
        guard snapshot.readiness == .ready, snapshot.lastError == nil else {
            return nil
        }
        let identities = Set(snapshot.sessions.compactMap { session in
            session.name == sessionName ? session.identity : nil
        })
        guard identities.count == 1 else { return nil }
        return identities.first
    }
}
