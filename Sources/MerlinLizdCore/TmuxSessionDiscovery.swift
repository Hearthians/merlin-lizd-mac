import Foundation

public enum TmuxSessionDiscoveryError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
}

public actor TmuxSessionDiscovery {
    private let processRunner: any InventoryProcessRunning
    private let localTmuxPath: String?

    public init(maxConcurrentProcesses: Int = 2) {
        let runner = FoundationInventoryProcessRunner()
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(1, maxConcurrentProcesses),
            underlying: runner
        )
        localTmuxPath = Self.resolveLocalTmux()
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
                return []
            }
            throw TmuxSessionDiscoveryError.commandFailed(exitCode: output.exitCode)
        }

        return TmuxSessionParser.parse(output.stdout)
    }

    private static func resolveLocalTmux() -> String? {
        let fileManager = FileManager.default
        return [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].first(where: fileManager.isExecutableFile(atPath:))
    }
}
