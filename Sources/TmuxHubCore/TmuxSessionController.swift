import Foundation

public enum TmuxSessionMutationError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case commandFailed(exitCode: Int32)
}

/// Performs the small set of state-changing tmux operations exposed by the UI.
public actor TmuxSessionController {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let executionPolicy: BoundedAsyncOperationRunner?
    private let localTmuxPath: String?
    private var configuringTargets: Set<TerminalTarget> = []

    public init(
        sshMasterPool: SSHMasterPool,
        maxConcurrentProcesses: Int = 4
    ) {
        let limit = max(1, maxConcurrentProcesses)
        executionPolicy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: limit,
            timeout: .seconds(30)
        )
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: limit,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(30),
                underlying: FoundationInventoryProcessRunner()
            )
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
        executionPolicy = nil
        self.localTmuxPath = localTmuxPath
    }

    public func applyConfiguration(target: TerminalTarget) async throws -> TmuxConfigurationResult {
        guard configuringTargets.insert(target).inserted else {
            throw TmuxConfigurationError.alreadyApplying
        }
        defer { configuringTargets.remove(target) }
        if case .local = target, localTmuxPath == nil {
            throw TmuxConfigurationError.tmuxNotFound
        }
        let command = try TmuxConfigurationPreset.command(
            target: target,
            localTmuxPath: localTmuxPath ?? "/opt/homebrew/bin/tmux"
        )
        let output = try await run(command, target: target)
        if output.exitCode == 10 { throw TmuxConfigurationError.tmuxNotFound }
        guard output.exitCode == 0 else {
            throw TmuxConfigurationError.commandFailed(
                exitCode: output.exitCode,
                detail: String(output.stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try TmuxConfigurationResult.parse(output.stdout)
    }

    public func rename(
        target: TerminalTarget,
        from currentName: String,
        to newName: String,
        identity: TmuxSessionIdentity? = nil
    ) async throws {
        let command = try TmuxCommands.renameTmuxSession(
            target: target,
            from: currentName,
            to: newName,
            identity: identity,
            localTmuxPath: try resolvedLocalTmuxPath(for: target)
        )
        try await requireSuccess(command, target: target)
    }

    public func terminate(
        target: TerminalTarget,
        sessionName: String
    ) async throws {
        let command = try TmuxCommands.terminateTmuxSession(
            target: target,
            sessionName: sessionName,
            localTmuxPath: try resolvedLocalTmuxPath(for: target)
        )
        try await requireSuccess(command, target: target)
    }

    private func requireSuccess(
        _ command: CommandSpec,
        target: TerminalTarget
    ) async throws {
        let output = try await run(command, target: target)
        guard output.exitCode == 0 else {
            throw TmuxSessionMutationError.commandFailed(
                exitCode: output.exitCode
            )
        }
    }

    private func run(
        _ command: CommandSpec,
        target: TerminalTarget
    ) async throws -> InventoryProcessOutput {
        guard let destination = target.sshDestination,
            let sshMasterPool
        else {
            return try await processRunner.run(command)
        }
        do {
            if let executionPolicy {
                return try await executionPolicy.run {
                    try await sshMasterPool.run(
                        command,
                        alias: destination,
                        replay: .never
                    )
                }
            }
            return try await sshMasterPool.run(
                command,
                alias: destination,
                replay: .never
            )
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            throw TmuxSessionMutationError.commandFailed(exitCode: exitCode)
        }
    }

    private func resolvedLocalTmuxPath(
        for target: TerminalTarget
    ) throws -> String {
        if case .local = target {
            guard let localTmuxPath else {
                throw TmuxSessionMutationError.localTmuxNotFound
            }
            return localTmuxPath
        }
        return localTmuxPath ?? "/opt/homebrew/bin/tmux"
    }
}

enum LocalTmuxResolver {
    static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        var candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("tmux")
                    .path
            })
        }
        var seen: Set<String> = []
        return candidates.first {
            seen.insert($0).inserted
                && fileManager.isExecutableFile(atPath: $0)
        }
    }
}
