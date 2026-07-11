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
    private let localTmuxPath: String?

    public init(maxConcurrentProcesses: Int = 1) {
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(1, maxConcurrentProcesses),
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(45),
                underlying: FoundationInventoryProcessRunner()
            )
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
        let output = try await processRunner.run(command)
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
