import Foundation

public enum TmuxSessionDiscoveryError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
}

public actor TmuxSessionDiscovery {
    private struct CacheEntry {
        let sessions: [TmuxSessionRecord]
        let fetchedAt: Date
    }

    private let processRunner: any InventoryProcessRunning
    private let localTmuxPath: String?
    private var cache: [TerminalTarget: CacheEntry] = [:]

    public init(maxConcurrentProcesses: Int = 2) {
        let runner = TimedInventoryProcessRunner(
            // `mlx worker login` can take ~25 seconds on a cold Worker even
            // when it succeeds, so share the inventory command budget.
            timeout: .seconds(45),
            underlying: FoundationInventoryProcessRunner()
        )
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(1, maxConcurrentProcesses),
            underlying: runner
        )
        localTmuxPath = LocalTmuxResolver.resolve()
    }

    init(
        processRunner: any InventoryProcessRunning,
        localTmuxPath: String? = "/opt/homebrew/bin/tmux"
    ) {
        self.processRunner = processRunner
        self.localTmuxPath = localTmuxPath
    }

    public func list(target: TerminalTarget) async throws -> [TmuxSessionRecord] {
        let localPath: String
        if case .local = target {
            guard let localTmuxPath else {
                throw TmuxSessionDiscoveryError.localTmuxNotFound
            }
            localPath = localTmuxPath
        } else {
            localPath = localTmuxPath ?? "/opt/homebrew/bin/tmux"
        }

        let command = try MerlinCommands.listTmuxSessions(
            target: target,
            localTmuxPath: localPath
        )
        let output = try await processRunner.run(command)
        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()

        if diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
        {
            throw TmuxSessionDiscoveryError.workerNotReady
        }

        guard output.exitCode == 0 else {
            if diagnostic.contains("no server running")
                || diagnostic.contains("no sessions")
            {
                cache[target] = CacheEntry(sessions: [], fetchedAt: Date())
                return []
            }
            throw TmuxSessionDiscoveryError.commandFailed(exitCode: output.exitCode)
        }

        let sessions = TmuxSessionParser.parse(output.stdout)
        cache[target] = CacheEntry(sessions: sessions, fetchedAt: Date())
        return sessions
    }

    public func cached(
        target: TerminalTarget,
        maximumAge: TimeInterval = 300
    ) -> [TmuxSessionRecord]? {
        guard
            let entry = cache[target],
            Date().timeIntervalSince(entry.fetchedAt) <= maximumAge
        else {
            return nil
        }
        return entry.sessions
    }

    public func recordRename(
        target: TerminalTarget,
        from currentName: String,
        to newName: String
    ) {
        guard let entry = cache[target] else { return }
        guard entry.sessions.contains(where: { $0.name == currentName }) else {
            return
        }
        let sessions = entry.sessions.map { session in
            session.name == currentName
                ? TmuxSessionRecord(name: newName)
                : session
        }
        // Renaming one known session does not prove the rest of the remote
        // inventory is fresh, so preserve the original expiry time.
        cache[target] = CacheEntry(
            sessions: sessions,
            fetchedAt: entry.fetchedAt
        )
    }
}
