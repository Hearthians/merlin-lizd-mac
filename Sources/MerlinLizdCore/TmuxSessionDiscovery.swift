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
    private let sshMasterPool: SSHMasterPool?
    private let localTmuxPath: String?
    private var cache: [TerminalTarget: CacheEntry] = [:]

    public init(
        sshMasterPool: SSHMasterPool,
        maxConcurrentProcesses: Int = 2
    ) {
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
        self.sshMasterPool = sshMasterPool
        localTmuxPath = LocalTmuxResolver.resolve()
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        processRunner: any InventoryProcessRunning,
        localTmuxPath: String? = "/opt/homebrew/bin/tmux"
    ) {
        self.sshMasterPool = sshMasterPool
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
        let output: InventoryProcessOutput
        if let alias = MerlinCommands.sshAlias(for: target), let sshMasterPool {
            do {
                output = try await sshMasterPool.run(
                    command,
                    alias: alias,
                    replay: .readOnly
                )
            } catch let SSHMasterPoolError.commandFailed(exitCode) {
                throw TmuxSessionDiscoveryError.commandFailed(exitCode: exitCode)
            }
        } else {
            output = try await processRunner.run(command)
        }
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

    public func recordTermination(
        target: TerminalTarget,
        sessionNames: Set<String>
    ) {
        guard !sessionNames.isEmpty, let entry = cache[target] else { return }
        cache[target] = CacheEntry(
            sessions: entry.sessions.filter {
                !sessionNames.contains($0.name)
            },
            fetchedAt: entry.fetchedAt
        )
    }
}
