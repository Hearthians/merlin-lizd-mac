import Foundation

public enum TmuxSessionDiscoveryError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case commandFailed(exitCode: Int32)
    case transport
}

public enum TmuxVerificationState: Equatable, Sendable {
    case idle
    case verifying
}

public enum TmuxRefreshLane: Sendable {
    case foreground
    case background
}

public enum TmuxReadinessEvidence: Equatable, Sendable {
    case ready
    case unknown
}

public struct TmuxSessionSnapshot: Equatable, Sendable {
    public let target: TerminalTarget
    public let sessions: [TmuxSessionRecord]
    public let readiness: TmuxReadinessEvidence
    public let fetchedAt: Date
    public let verification: TmuxVerificationState
    public let lastError: TmuxSessionDiscoveryError?

    public func isFresh(
        at now: Date,
        maximumAge: TimeInterval = 30
    ) -> Bool {
        readiness == .ready
            && lastError == nil
            && now.timeIntervalSince(fetchedAt) <= maximumAge
    }
}

/// Coalesces concurrent refreshes and keeps stale session evidence visible
/// while SSH reconnects, so navigating between hosts never blanks the UI.
public actor TmuxSessionDiscovery {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let foregroundPolicy: BoundedAsyncOperationRunner?
    private let backgroundPolicy: BoundedAsyncOperationRunner?
    private let localTmuxPath: String?
    private let now: @Sendable () -> Date
    private var snapshots: [TerminalTarget: TmuxSessionSnapshot] = [:]
    private var refreshes: [TerminalTarget: Task<TmuxSessionSnapshot, Never>] = [:]
    private var generations: [TerminalTarget: UInt64] = [:]
    private var mutationRevisions: [TerminalTarget: UInt64] = [:]

    public init(
        sshMasterPool: SSHMasterPool,
        maxConcurrentBackgroundRefreshes: Int = 8
    ) {
        let backgroundLimit = max(1, maxConcurrentBackgroundRefreshes)
        foregroundPolicy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: 8,
            timeout: .seconds(30)
        )
        backgroundPolicy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: backgroundLimit,
            timeout: .seconds(30)
        )
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: backgroundLimit,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(30),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        self.sshMasterPool = sshMasterPool
        localTmuxPath = LocalTmuxResolver.resolve()
        now = Date.init
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        processRunner: any InventoryProcessRunning,
        localTmuxPath: String? = "/opt/homebrew/bin/tmux",
        now: @escaping @Sendable () -> Date = Date.init,
        foregroundPolicy: BoundedAsyncOperationRunner? = nil,
        backgroundPolicy: BoundedAsyncOperationRunner? = nil
    ) {
        self.sshMasterPool = sshMasterPool
        self.processRunner = processRunner
        self.localTmuxPath = localTmuxPath
        self.now = now
        self.foregroundPolicy = foregroundPolicy
        self.backgroundPolicy = backgroundPolicy
    }

    public func snapshot(target: TerminalTarget) -> TmuxSessionSnapshot? {
        guard let snapshot = snapshots[target] else { return nil }
        if !snapshot.isFresh(at: now()), refreshes[target] == nil {
            _ = startRefresh(target: target, lane: .background)
        }
        return snapshots[target]
    }

    public func peekSnapshot(target: TerminalTarget) -> TmuxSessionSnapshot? {
        snapshots[target]
    }

    public func refresh(
        target: TerminalTarget,
        lane: TmuxRefreshLane = .foreground
    ) async -> TmuxSessionSnapshot {
        let task = refreshes[target] ?? startRefresh(target: target, lane: lane)
        return await task.value
    }

    public func refreshIfStale(
        target: TerminalTarget,
        maximumAge: TimeInterval = 30,
        lane: TmuxRefreshLane = .foreground
    ) async -> TmuxSessionSnapshot {
        if let snapshot = snapshots[target],
            snapshot.isFresh(at: now(), maximumAge: maximumAge)
        {
            return snapshot
        }
        return await refresh(target: target, lane: lane)
    }

    public func recordRename(
        target: TerminalTarget,
        from currentName: String,
        to newName: String,
        identity: TmuxSessionIdentity? = nil
    ) {
        mutationRevisions[target, default: 0] &+= 1
        guard let snapshot = snapshots[target] else { return }
        let sessions = snapshot.sessions.map { session in
            let matches = identity.map { session.identity == $0 }
                ?? (session.identity == nil && session.name == currentName)
            return matches
                ? TmuxSessionRecord(name: newName, identity: session.identity)
                : session
        }
        snapshots[target] = replacingSessions(snapshot, sessions: sessions)
    }

    public func recordTermination(
        target: TerminalTarget,
        sessionNames: Set<String>
    ) {
        guard !sessionNames.isEmpty else { return }
        mutationRevisions[target, default: 0] &+= 1
        guard let snapshot = snapshots[target] else { return }
        let sessions = snapshot.sessions.filter {
            !sessionNames.contains($0.name)
        }
        snapshots[target] = replacingSessions(snapshot, sessions: sessions)
    }

    private func startRefresh(
        target: TerminalTarget,
        lane: TmuxRefreshLane
    ) -> Task<TmuxSessionSnapshot, Never> {
        let previous = snapshots[target]
        if let previous {
            snapshots[target] = TmuxSessionSnapshot(
                target: target,
                sessions: previous.sessions,
                readiness: previous.readiness,
                fetchedAt: previous.fetchedAt,
                verification: .verifying,
                lastError: previous.lastError
            )
        }
        let generation = (generations[target] ?? 0) &+ 1
        generations[target] = generation
        let startingMutationRevision = mutationRevisions[target] ?? 0
        let task = Task {
            let result = await Self.load(
                target: target,
                previous: previous,
                runner: processRunner,
                pool: sshMasterPool,
                policy: lane == .foreground ? foregroundPolicy : backgroundPolicy,
                localTmuxPath: localTmuxPath,
                now: now
            )
            return complete(
                result,
                target: target,
                generation: generation,
                startingMutationRevision: startingMutationRevision
            )
        }
        refreshes[target] = task
        return task
    }

    private func complete(
        _ result: TmuxSessionSnapshot,
        target: TerminalTarget,
        generation: UInt64,
        startingMutationRevision: UInt64
    ) -> TmuxSessionSnapshot {
        guard generations[target] == generation else {
            return snapshots[target] ?? result
        }
        refreshes[target] = nil
        if mutationRevisions[target, default: 0] != startingMutationRevision,
            let current = snapshots[target]
        {
            let preserved = TmuxSessionSnapshot(
                target: current.target,
                sessions: current.sessions,
                readiness: current.readiness,
                fetchedAt: current.fetchedAt,
                verification: .idle,
                lastError: current.lastError
            )
            snapshots[target] = preserved
            return preserved
        }
        snapshots[target] = result
        return result
    }

    private static func load(
        target: TerminalTarget,
        previous: TmuxSessionSnapshot?,
        runner: any InventoryProcessRunning,
        pool: SSHMasterPool?,
        policy: BoundedAsyncOperationRunner?,
        localTmuxPath: String?,
        now: @Sendable () -> Date
    ) async -> TmuxSessionSnapshot {
        let localPath: String
        if case .local = target {
            guard let localTmuxPath else {
                return failure(
                    target: target,
                    previous: previous,
                    error: .localTmuxNotFound,
                    now: now()
                )
            }
            localPath = localTmuxPath
        } else {
            localPath = localTmuxPath ?? "/opt/homebrew/bin/tmux"
        }

        do {
            let command = try TmuxCommands.listTmuxSessions(
                target: target,
                localTmuxPath: localPath
            )
            let output: InventoryProcessOutput
            if let destination = target.sshDestination, let pool {
                if let policy {
                    output = try await policy.run {
                        try await pool.run(
                            command,
                            alias: destination,
                            replay: .readOnly
                        )
                    }
                } else {
                    output = try await pool.run(
                        command,
                        alias: destination,
                        replay: .readOnly
                    )
                }
            } else {
                output = try await runner.run(command)
            }

            let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
            if output.exitCode != 0 {
                if diagnostic.contains("no server running")
                    || diagnostic.contains("no sessions")
                {
                    return success(target: target, sessions: [], now: now())
                }
                return failure(
                    target: target,
                    previous: previous,
                    error: .commandFailed(exitCode: output.exitCode),
                    now: now()
                )
            }
            return success(
                target: target,
                sessions: TmuxSessionParser.parse(output.stdout),
                now: now()
            )
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            return failure(
                target: target,
                previous: previous,
                error: .commandFailed(exitCode: exitCode),
                now: now()
            )
        } catch {
            return failure(
                target: target,
                previous: previous,
                error: .transport,
                now: now()
            )
        }
    }

    private static func success(
        target: TerminalTarget,
        sessions: [TmuxSessionRecord],
        now: Date
    ) -> TmuxSessionSnapshot {
        TmuxSessionSnapshot(
            target: target,
            sessions: sessions,
            readiness: .ready,
            fetchedAt: now,
            verification: .idle,
            lastError: nil
        )
    }

    private static func failure(
        target: TerminalTarget,
        previous: TmuxSessionSnapshot?,
        error: TmuxSessionDiscoveryError,
        now: Date
    ) -> TmuxSessionSnapshot {
        TmuxSessionSnapshot(
            target: target,
            sessions: previous?.sessions ?? [],
            readiness: previous?.readiness ?? .unknown,
            fetchedAt: previous?.fetchedAt ?? now,
            verification: .idle,
            lastError: error
        )
    }

    private func replacingSessions(
        _ snapshot: TmuxSessionSnapshot,
        sessions: [TmuxSessionRecord]
    ) -> TmuxSessionSnapshot {
        TmuxSessionSnapshot(
            target: snapshot.target,
            sessions: sessions,
            readiness: snapshot.readiness,
            fetchedAt: snapshot.fetchedAt,
            verification: snapshot.verification,
            lastError: snapshot.lastError
        )
    }
}
