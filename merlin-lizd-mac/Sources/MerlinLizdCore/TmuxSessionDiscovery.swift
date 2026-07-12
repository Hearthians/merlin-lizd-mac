import Foundation

typealias TmuxSnapshotDate = Date

public enum TmuxSessionDiscoveryError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
    case transport
}

public enum TmuxVerificationState: Equatable, Sendable {
    case idle
    case verifying
}

public enum TmuxReadinessEvidence: Equatable, Sendable {
    case ready
    case workerNotReady
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
        maximumAge: TimeInterval = 60
    ) -> Bool {
        readiness == .ready
            && lastError == nil
            && now.timeIntervalSince(fetchedAt) <= maximumAge
    }
}

public actor TmuxSessionDiscovery {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let localTmuxPath: String?
    private let now: @Sendable () -> Date
    private var snapshots: [TerminalTarget: TmuxSessionSnapshot] = [:]
    private var refreshes: [
        TerminalTarget: Task<TmuxSessionSnapshot, Never>
    ] = [:]
    private var refreshGenerations: [TerminalTarget: UInt64] = [:]

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
        now = Date.init
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        processRunner: any InventoryProcessRunning,
        localTmuxPath: String? = "/opt/homebrew/bin/tmux",
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sshMasterPool = sshMasterPool
        self.processRunner = processRunner
        self.localTmuxPath = localTmuxPath
        self.now = now
    }

    public func snapshot(
        target: TerminalTarget
    ) -> TmuxSessionSnapshot? {
        guard let snapshot = snapshots[target] else { return nil }
        guard !snapshot.isFresh(at: now()) else { return snapshot }
        if refreshes[target] == nil {
            _ = startRefresh(target: target)
        }
        return snapshots[target]
    }

    /// Returns current evidence without starting or joining remote work.
    public func peekSnapshot(
        target: TerminalTarget
    ) -> TmuxSessionSnapshot? {
        snapshots[target]
    }

    public func refresh(target: TerminalTarget) async -> TmuxSessionSnapshot {
        let task = refreshes[target] ?? startRefresh(target: target)
        return await task.value
    }

    /// Atomically joins current verification, returns fresh evidence, or starts
    /// one refresh after rechecking state inside the discovery actor.
    public func refreshIfStale(
        target: TerminalTarget,
        maximumAge: TimeInterval = 60
    ) async -> TmuxSessionSnapshot {
        if let snapshot = snapshots[target],
            snapshot.isFresh(at: now(), maximumAge: maximumAge)
        {
            return snapshot
        }
        return await refresh(target: target)
    }

    func cancelRefresh(target: TerminalTarget) {
        refreshes[target]?.cancel()
    }

    public func cached(
        target: TerminalTarget,
        maximumAge: TimeInterval = 300
    ) -> [TmuxSessionRecord]? {
        guard
            let snapshot = snapshots[target],
            now().timeIntervalSince(snapshot.fetchedAt) <= maximumAge
        else { return nil }
        return snapshot.sessions
    }

    public func list(target: TerminalTarget) async throws -> [TmuxSessionRecord] {
        let snapshot = await refresh(target: target)
        if let lastError = snapshot.lastError { throw lastError }
        return snapshot.sessions
    }

    public func recordRename(
        target: TerminalTarget,
        from currentName: String,
        to newName: String
    ) {
        guard let snapshot = snapshots[target] else { return }
        guard snapshot.sessions.contains(where: { $0.name == currentName }) else {
            return
        }
        let sessions = snapshot.sessions.map { session in
            session.name == currentName
                ? TmuxSessionRecord(name: newName)
                : session
        }
        snapshots[target] = replacingSessions(in: snapshot, with: sessions)
    }

    public func recordTermination(
        target: TerminalTarget,
        sessionNames: Set<String>
    ) {
        guard !sessionNames.isEmpty, let snapshot = snapshots[target] else {
            return
        }
        let sessions = snapshot.sessions.filter {
            !sessionNames.contains($0.name)
        }
        snapshots[target] = replacingSessions(in: snapshot, with: sessions)
    }

    private func startRefresh(
        target: TerminalTarget
    ) -> Task<TmuxSessionSnapshot, Never> {
        let previous = snapshots[target]
        if let previous {
            snapshots[target] = TmuxSessionSnapshot(
                target: previous.target,
                sessions: previous.sessions,
                readiness: previous.readiness,
                fetchedAt: previous.fetchedAt,
                verification: .verifying,
                lastError: previous.lastError
            )
        }

        let generation = (refreshGenerations[target] ?? 0) &+ 1
        refreshGenerations[target] = generation
        let processRunner = processRunner
        let sshMasterPool = sshMasterPool
        let localTmuxPath = localTmuxPath
        let now = now
        let task = Task {
            let result = await Self.loadSnapshot(
                target: target,
                previous: previous,
                processRunner: processRunner,
                sshMasterPool: sshMasterPool,
                localTmuxPath: localTmuxPath,
                now: now
            )
            return self.completeRefresh(
                result,
                target: target,
                generation: generation
            )
        }
        refreshes[target] = task
        return task
    }

    private func completeRefresh(
        _ snapshot: TmuxSessionSnapshot,
        target: TerminalTarget,
        generation: UInt64
    ) -> TmuxSessionSnapshot {
        guard refreshGenerations[target] == generation else {
            return snapshots[target] ?? snapshot
        }
        let committed: TmuxSessionSnapshot
        if snapshot.lastError != nil, let latest = snapshots[target] {
            committed = TmuxSessionSnapshot(
                target: latest.target,
                sessions: latest.sessions,
                readiness: snapshot.readiness,
                fetchedAt: latest.fetchedAt,
                verification: .idle,
                lastError: snapshot.lastError
            )
        } else {
            committed = snapshot
        }
        snapshots[target] = committed
        refreshes[target] = nil
        return committed
    }

    private func replacingSessions(
        in snapshot: TmuxSessionSnapshot,
        with sessions: [TmuxSessionRecord]
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

    private static func loadSnapshot(
        target: TerminalTarget,
        previous: TmuxSessionSnapshot?,
        processRunner: any InventoryProcessRunning,
        sshMasterPool: SSHMasterPool?,
        localTmuxPath: String?,
        now: @Sendable () -> Date
    ) async -> TmuxSessionSnapshot {
        let output: InventoryProcessOutput
        do {
            let localPath: String
            if case .local = target {
                guard let localTmuxPath else {
                    return failureSnapshot(
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

            let command: CommandSpec
            if case .worker = target {
                command = try MerlinCommands.warmWorker(target: target)
            } else {
                command = try MerlinCommands.listTmuxSessions(
                    target: target,
                    localTmuxPath: localPath
                )
            }
            if let alias = MerlinCommands.sshAlias(for: target),
                let sshMasterPool
            {
                output = try await sshMasterPool.run(
                    command,
                    alias: alias,
                    replay: .readOnly
                )
            } else {
                output = try await processRunner.run(command)
            }
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            return failureSnapshot(
                target: target,
                previous: previous,
                error: .commandFailed(exitCode: exitCode),
                now: now()
            )
        } catch {
            return failureSnapshot(
                target: target,
                previous: previous,
                error: .transport,
                now: now()
            )
        }

        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
        if diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
        {
            return workerNotReadySnapshot(
                target: target,
                previous: previous,
                now: now()
            )
        }

        let isWorker: Bool
        let workerWasReady: Bool
        let sessionOutput: String
        if case .worker = target {
            isWorker = true
            let lines = output.stdout.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            let markerIndex = lines.firstIndex(of: "__MLZ_READY__")
            workerWasReady = markerIndex != nil
            sessionOutput = markerIndex.map {
                lines[lines.index(after: $0)...].joined(separator: "\n")
            } ?? output.stdout
        } else {
            isWorker = false
            workerWasReady = false
            sessionOutput = output.stdout
        }

        if isWorker, !workerWasReady, output.exitCode == 0 {
            return failureSnapshot(
                target: target,
                previous: previous,
                error: .transport,
                now: now()
            )
        }

        guard output.exitCode == 0 else {
            if (diagnostic.contains("no server running")
                || diagnostic.contains("no sessions"))
                && !(isWorker && !workerWasReady)
            {
                return authoritativeSnapshot(
                    target: target,
                    sessions: [],
                    now: now()
                )
            }
            return failureSnapshot(
                target: target,
                previous: previous,
                error: .commandFailed(exitCode: output.exitCode),
                now: now()
            )
        }

        return authoritativeSnapshot(
            target: target,
            sessions: TmuxSessionParser.parse(sessionOutput),
            now: now()
        )
    }

    private static func authoritativeSnapshot(
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

    private static func failureSnapshot(
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

    private static func workerNotReadySnapshot(
        target: TerminalTarget,
        previous: TmuxSessionSnapshot?,
        now: Date
    ) -> TmuxSessionSnapshot {
        TmuxSessionSnapshot(
            target: target,
            sessions: previous?.sessions ?? [],
            readiness: .workerNotReady,
            fetchedAt: previous?.fetchedAt ?? now,
            verification: .idle,
            lastError: .workerNotReady
        )
    }
}
