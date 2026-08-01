import Foundation

public enum TmuxSessionMutationError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
}

/// Applies tmux mutations through the same bounded, cancellation-aware child
/// process infrastructure used by inventory and Devbox lifecycle commands.
public actor TmuxSessionController {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let pooledExecutionPolicy: BoundedAsyncOperationRunner?
    private let localTmuxPath: String?

    public init(
        sshMasterPool: SSHMasterPool,
        maxConcurrentProcesses: Int = 4
    ) {
        pooledExecutionPolicy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: max(1, maxConcurrentProcesses),
            timeout: .seconds(45)
        )
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(1, maxConcurrentProcesses),
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(45),
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
        pooledExecutionPolicy = nil
        self.localTmuxPath = localTmuxPath
    }

    public func rename(
        target: TerminalTarget,
        from currentName: String,
        to newName: String
    ) async throws {
        let localPath: String
        if case .local = target {
            guard let localTmuxPath else {
                throw TmuxSessionMutationError.localTmuxNotFound
            }
            localPath = localTmuxPath
        } else {
            localPath = localTmuxPath ?? "/opt/homebrew/bin/tmux"
        }

        let command = try MerlinCommands.renameTmuxSession(
            target: target,
            from: currentName,
            to: newName,
            localTmuxPath: localPath
        )
        let output = try await run(command, target: target)
        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
        if diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
        {
            throw TmuxSessionMutationError.workerNotReady
        }
        guard output.exitCode == 0 else {
            throw TmuxSessionMutationError.commandFailed(exitCode: output.exitCode)
        }
    }

    public func terminate(
        target: TerminalTarget,
        sessionName: String
    ) async throws {
        let localPath: String
        if case .local = target {
            guard let localTmuxPath else {
                throw TmuxSessionMutationError.localTmuxNotFound
            }
            localPath = localTmuxPath
        } else {
            localPath = localTmuxPath ?? "/opt/homebrew/bin/tmux"
        }

        let command = try MerlinCommands.terminateTmuxSession(
            target: target,
            sessionName: sessionName,
            localTmuxPath: localPath
        )
        let output = try await run(command, target: target)
        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
        if diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
        {
            throw TmuxSessionMutationError.workerNotReady
        }
        guard output.exitCode == 0 else {
            throw TmuxSessionMutationError.commandFailed(exitCode: output.exitCode)
        }
    }

    private func run(
        _ command: CommandSpec,
        target: TerminalTarget
    ) async throws -> InventoryProcessOutput {
        guard
            let alias = MerlinCommands.sshConnectionTarget(for: target),
            let sshMasterPool
        else {
            return try await processRunner.run(command)
        }
        do {
            if let pooledExecutionPolicy {
                return try await pooledExecutionPolicy.run {
                    try await sshMasterPool.run(
                        command,
                        alias: alias,
                        replay: .never
                    )
                }
            }
            return try await sshMasterPool.run(
                command,
                alias: alias,
                replay: .never
            )
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            throw TmuxSessionMutationError.commandFailed(exitCode: exitCode)
        }
    }
}

enum LocalTmuxResolver {
    static func resolve(
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].first(where: isExecutable)
    }
}
