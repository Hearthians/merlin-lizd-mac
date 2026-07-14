import Foundation

public enum TmuxSessionMutationError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
}

/// Applies tmux mutations through the same bounded, cancellation-aware child
/// process infrastructure used by inventory and Devbox lifecycle commands.
public actor TmuxSessionController: TmuxSurfaceControlling {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let pooledExecutionPolicy: BoundedAsyncOperationRunner?
    private let localTmuxPath: String?
    private var temporaryPanes: [TemporaryPaneKey: OwnedTemporaryPane] = [:]

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
        to newName: String,
        identity: TmuxSessionIdentity? = nil
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
            identity: identity,
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

    public func currentSurface(route: TmuxRoute) async throws -> TmuxSurface {
        try validate(route: route)
        let command = try MerlinCommands.currentTmuxSurface(
            target: route.target,
            sessionName: route.sessionName,
            localTmuxPath: try resolvedLocalTmuxPath(for: route.target)
        )
        return try await readSurface(command, route: route)
    }

    public func select(
        _ selection: TmuxVisibleSelection,
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
        try validate(surface: from, route: route)
        let localPath = try resolvedLocalTmuxPath(for: route.target)
        let command = switch selection {
        case .nextWindow, .previousWindow, .windowIndex:
            try MerlinCommands.selectTmuxWindow(
                target: route.target,
                sessionName: route.sessionName,
                selection: selection,
                localTmuxPath: localPath
            )
        case .paneLeft, .paneRight, .paneUp, .paneDown,
            .nextPane, .previousPane:
            try MerlinCommands.selectTmuxPane(
                target: route.target,
                paneID: from.paneID,
                selection: selection,
                localTmuxPath: localPath
            )
        }
        try await runSurfaceMutation(command, target: route.target)
        return try await currentSurface(route: route)
    }

    public func createTemporaryPane(
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
        try validate(surface: from, route: route)
        let command = try MerlinCommands.splitTmuxPane(
            target: route.target,
            paneID: from.paneID,
            localTmuxPath: try resolvedLocalTmuxPath(for: route.target)
        )
        let output = try await runSurfaceCommand(
            command,
            target: route.target,
            replay: .never
        )
        try checkSurfaceOutput(output)
        guard let location = TmuxSurfaceParser.parsePaneLocation(output.stdout) else {
            throw TmuxSurfaceControlError.invalidSurfaceOutput
        }

        let temporary = try await currentSurface(route: route)
        guard
            temporary.windowID == location.windowID,
            temporary.paneID == location.paneID
        else {
            throw TmuxSurfaceControlError.createdPaneNotCurrent
        }
        temporaryPanes[TemporaryPaneKey(
            target: route.target,
            sessionIdentity: route.expectedIdentity,
            paneID: temporary.paneID
        )] = OwnedTemporaryPane(
            route: route,
            origin: from,
            temporary: temporary
        )
        return temporary
    }

    public func closeTemporaryPane(
        _ paneID: String,
        restoring origin: TmuxSurface,
        route: TmuxRoute
    ) async throws {
        try validate(surface: origin, route: route)
        guard MerlinIdentifierValidator.isTmuxPaneID(paneID) else {
            throw CommandValidationError.invalidTmuxPaneID
        }
        let key = TemporaryPaneKey(
            target: route.target,
            sessionIdentity: route.expectedIdentity,
            paneID: paneID
        )
        guard
            let ownership = temporaryPanes[key],
            ownership.route == route,
            ownership.origin == origin
        else {
            throw TmuxSurfaceControlError.paneNotOwned(paneID: paneID)
        }

        let localPath = try resolvedLocalTmuxPath(for: route.target)
        let inspection = try MerlinCommands.tmuxPaneSurface(
            target: route.target,
            paneID: paneID,
            localTmuxPath: localPath
        )
        let leasedSurface = try await readSurface(
            inspection,
            route: route,
            missingLeasePaneID: paneID
        )
        guard leasedSurface.paneID == ownership.temporary.paneID else {
            throw TmuxSurfaceControlError.leasePaneMissing(paneID: paneID)
        }

        let kill = try MerlinCommands.killTmuxPane(
            target: route.target,
            paneID: paneID,
            localTmuxPath: localPath
        )
        try await runSurfaceMutation(kill, target: route.target)
        temporaryPanes[key] = nil

        do {
            let restoreWindow = try MerlinCommands.restoreTmuxWindow(
                target: route.target,
                windowID: origin.windowID,
                localTmuxPath: localPath
            )
            try await runSurfaceMutation(restoreWindow, target: route.target)

            let restorePane = try MerlinCommands.restoreTmuxPane(
                target: route.target,
                paneID: origin.paneID,
                localTmuxPath: localPath
            )
            try await runSurfaceMutation(restorePane, target: route.target)

            let restored = try await currentSurface(route: route)
            guard
                restored.windowID == origin.windowID,
                restored.paneID == origin.paneID
            else {
                throw TmuxSurfaceControlError.restoreFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TmuxSurfaceControlError.restoreFailed
        }
    }

    private func readSurface(
        _ command: CommandSpec,
        route: TmuxRoute,
        missingLeasePaneID: String? = nil
    ) async throws -> TmuxSurface {
        let output = try await runSurfaceCommand(
            command,
            target: route.target,
            replay: .readOnly
        )
        let diagnostic = diagnostic(for: output)
        if isWorkerNotReady(diagnostic) {
            throw TmuxSurfaceControlError.workerNotReady
        }
        guard output.exitCode == 0 else {
            if let missingLeasePaneID,
                diagnostic.contains("can't find pane")
                    || diagnostic.contains("no such pane")
            {
                throw TmuxSurfaceControlError.leasePaneMissing(
                    paneID: missingLeasePaneID
                )
            }
            throw TmuxSurfaceControlError.commandFailed(
                exitCode: output.exitCode
            )
        }
        guard let surface = TmuxSurfaceParser.parse(output.stdout) else {
            throw TmuxSurfaceControlError.invalidSurfaceOutput
        }
        guard surface.sessionIdentity == route.expectedIdentity else {
            throw TmuxSurfaceControlError.sessionIdentityMismatch(
                expected: route.expectedIdentity,
                actual: surface.sessionIdentity
            )
        }
        return surface
    }

    private func runSurfaceMutation(
        _ command: CommandSpec,
        target: TerminalTarget
    ) async throws {
        let output = try await runSurfaceCommand(
            command,
            target: target,
            replay: .never
        )
        try checkSurfaceOutput(output)
    }

    private func checkSurfaceOutput(
        _ output: InventoryProcessOutput
    ) throws {
        let diagnostic = diagnostic(for: output)
        if isWorkerNotReady(diagnostic) {
            throw TmuxSurfaceControlError.workerNotReady
        }
        guard output.exitCode == 0 else {
            throw TmuxSurfaceControlError.commandFailed(
                exitCode: output.exitCode
            )
        }
    }

    private func runSurfaceCommand(
        _ command: CommandSpec,
        target: TerminalTarget,
        replay: SSHReplayPolicy
    ) async throws -> InventoryProcessOutput {
        do {
            return try await run(command, target: target, replay: replay)
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            throw TmuxSurfaceControlError.commandFailed(exitCode: exitCode)
        } catch let TmuxSessionMutationError.commandFailed(exitCode) {
            throw TmuxSurfaceControlError.commandFailed(exitCode: exitCode)
        }
    }

    private func validate(route: TmuxRoute) throws {
        guard
            route.expectedIdentity.createdAtEpoch >= 0,
            MerlinIdentifierValidator.isTmuxSessionID(
                route.expectedIdentity.serverSessionID
            )
        else {
            throw CommandValidationError.invalidTmuxSessionID
        }
        guard MerlinIdentifierValidator.isTmuxSessionName(route.sessionName) else {
            throw CommandValidationError.invalidSessionName
        }
    }

    private func validate(
        surface: TmuxSurface,
        route: TmuxRoute
    ) throws {
        try validate(route: route)
        guard surface.sessionIdentity == route.expectedIdentity else {
            throw TmuxSurfaceControlError.sessionIdentityMismatch(
                expected: route.expectedIdentity,
                actual: surface.sessionIdentity
            )
        }
        guard MerlinIdentifierValidator.isTmuxWindowID(surface.windowID) else {
            throw CommandValidationError.invalidTmuxWindowID
        }
        guard MerlinIdentifierValidator.isTmuxPaneID(surface.paneID) else {
            throw CommandValidationError.invalidTmuxPaneID
        }
    }

    private func resolvedLocalTmuxPath(
        for target: TerminalTarget
    ) throws -> String {
        if case .local = target {
            guard let localTmuxPath else {
                throw TmuxSurfaceControlError.localTmuxNotFound
            }
            return localTmuxPath
        }
        return localTmuxPath ?? "/opt/homebrew/bin/tmux"
    }

    private func diagnostic(for output: InventoryProcessOutput) -> String {
        (output.stdout + "\n" + output.stderr).lowercased()
    }

    private func isWorkerNotReady(_ diagnostic: String) -> Bool {
        diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
    }

    private func run(
        _ command: CommandSpec,
        target: TerminalTarget,
        replay: SSHReplayPolicy = .never
    ) async throws -> InventoryProcessOutput {
        guard
            let alias = MerlinCommands.sshAlias(for: target),
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
                        replay: replay
                    )
                }
            }
            return try await sshMasterPool.run(
                command,
                alias: alias,
                replay: replay
            )
        } catch let SSHMasterPoolError.commandFailed(exitCode) {
            throw TmuxSessionMutationError.commandFailed(exitCode: exitCode)
        }
    }
}

private struct TemporaryPaneKey: Hashable, Sendable {
    let target: TerminalTarget
    let sessionIdentity: TmuxSessionIdentity
    let paneID: String
}

private struct OwnedTemporaryPane: Sendable {
    let route: TmuxRoute
    let origin: TmuxSurface
    let temporary: TmuxSurface
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
