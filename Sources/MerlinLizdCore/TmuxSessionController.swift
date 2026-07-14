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
    private let surfaceOperations = TmuxSurfaceOperationGate()
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
        return try await surfaceOperations.run(for: route.conversationKey) { [self] in
            let surface = try await currentSurfaceUnlocked(route: route)
            try Task.checkCancellation()
            return surface
        }
    }

    private func currentSurfaceUnlocked(
        route: TmuxRoute
    ) async throws -> TmuxSurface {
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
        return try await surfaceOperations.run(for: route.conversationKey) { [self] in
            try await selectUnlocked(selection, from: from, route: route)
        }
    }

    private func selectUnlocked(
        _ selection: TmuxVisibleSelection,
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
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
        try Task.checkCancellation()
        let selected = try await currentSurfaceUnlocked(route: route)
        try Task.checkCancellation()
        return selected
    }

    public func createTemporaryPane(
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
        try validate(surface: from, route: route)
        return try await surfaceOperations.run(for: route.conversationKey) { [self] in
            try await createTemporaryPaneUnlocked(from: from, route: route)
        }
    }

    private func createTemporaryPaneUnlocked(
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface {
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

        let retained = RetainedTemporaryPane(
            windowID: location.windowID,
            paneID: location.paneID
        )
        let key = TemporaryPaneKey(
            conversationKey: route.conversationKey,
            paneID: location.paneID
        )
        temporaryPanes[key] = OwnedTemporaryPane(
            origin: from,
            temporary: TmuxSurface(
                sessionIdentity: route.expectedIdentity,
                windowID: location.windowID,
                paneID: location.paneID,
                currentCommand: ""
            )
        )

        let temporary: TmuxSurface
        do {
            try Task.checkCancellation()
            temporary = try await currentSurfaceUnlocked(route: route)
            try Task.checkCancellation()
        } catch {
            throw TmuxSurfaceControlError.temporaryPaneRetained(
                pane: retained,
                reason: retainedPaneReason(for: error)
            )
        }
        guard
            temporary.windowID == location.windowID,
            temporary.paneID == location.paneID
        else {
            throw TmuxSurfaceControlError.temporaryPaneRetained(
                pane: retained,
                reason: .createdPaneNotCurrent(actual: RetainedSurfaceLocation(
                    sessionIdentity: temporary.sessionIdentity,
                    windowID: temporary.windowID,
                    paneID: temporary.paneID
                ))
            )
        }
        temporaryPanes[key] = OwnedTemporaryPane(
            origin: from,
            temporary: temporary
        )
        return temporary
    }

    private func retainedPaneReason(
        for error: Error
    ) -> RetainedTemporaryPaneReason {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if error is InventoryProcessTimeoutError {
            return .timedOut
        }
        if let error = error as? SSHMasterPoolError {
            return switch error {
            case .shuttingDown:
                .transportUnavailable
            case let .commandFailed(exitCode):
                .commandFailed(exitCode: exitCode)
            }
        }
        guard let error = error as? TmuxSurfaceControlError else {
            return .unavailable
        }
        return switch error {
        case .localTmuxNotFound:
            .transportUnavailable
        case .workerNotReady:
            .workerNotReady
        case let .commandFailed(exitCode):
            .commandFailed(exitCode: exitCode)
        case .invalidSurfaceOutput:
            .invalidSurfaceOutput
        case let .sessionIdentityMismatch(expected, actual):
            .sessionIdentityMismatch(expected: expected, actual: actual)
        case let .temporaryPaneRetained(_, reason):
            reason
        case .paneNotOwned, .leasePaneMissing, .restoreFailed:
            .unavailable
        }
    }

    public func closeTemporaryPane(
        _ paneID: String,
        restoring origin: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxTemporaryPaneCloseOutcome {
        try validate(surface: origin, route: route)
        guard MerlinIdentifierValidator.isTmuxPaneID(paneID) else {
            throw CommandValidationError.invalidTmuxPaneID
        }
        do {
            return try await surfaceOperations.run(
                for: route.conversationKey
            ) { [self] in
                await closeTemporaryPaneUnlocked(
                    paneID,
                    restoring: origin,
                    route: route
                )
            }
        } catch {
            return .notCommitted(reason: closeFailureReason(for: error))
        }
    }

    private func closeTemporaryPaneUnlocked(
        _ paneID: String,
        restoring origin: TmuxSurface,
        route: TmuxRoute
    ) async -> TmuxTemporaryPaneCloseOutcome {
        let key = TemporaryPaneKey(
            conversationKey: route.conversationKey,
            paneID: paneID
        )
        guard
            let ownership = temporaryPanes[key],
            ownership.origin == origin
        else {
            return .notCommitted(reason: .paneNotOwned)
        }

        let localPath: String
        do {
            localPath = try resolvedLocalTmuxPath(for: route.target)
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
            try Task.checkCancellation()
            guard leasedSurface.paneID == ownership.temporary.paneID else {
                return .notCommitted(reason: .leasePaneMissing)
            }

            let kill = try MerlinCommands.killTmuxPane(
                target: route.target,
                paneID: paneID,
                localTmuxPath: localPath
            )
            try await runSurfaceMutation(kill, target: route.target)
        } catch {
            return .notCommitted(reason: closeFailureReason(for: error))
        }
        temporaryPanes[key] = nil

        do {
            try Task.checkCancellation()
            let restoreWindow = try MerlinCommands.restoreTmuxWindow(
                target: route.target,
                windowID: origin.windowID,
                localTmuxPath: localPath
            )
            try await runSurfaceMutation(restoreWindow, target: route.target)
            try Task.checkCancellation()

            let restorePane = try MerlinCommands.restoreTmuxPane(
                target: route.target,
                paneID: origin.paneID,
                localTmuxPath: localPath
            )
            try await runSurfaceMutation(restorePane, target: route.target)
            try Task.checkCancellation()

            let restored = try await currentSurfaceUnlocked(route: route)
            try Task.checkCancellation()
            guard
                restored.windowID == origin.windowID,
                restored.paneID == origin.paneID
            else {
                throw TmuxSurfaceControlError.restoreFailed
            }
            return .closed(restoration: .restored)
        } catch {
            return .closed(
                restoration: .failed(restoreFailureReason(for: error))
            )
        }
    }

    private func closeFailureReason(
        for error: Error
    ) -> TmuxTemporaryPaneCloseFailureReason {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if error is InventoryProcessTimeoutError {
            return .timedOut
        }
        if let error = error as? SSHMasterPoolError {
            return switch error {
            case .shuttingDown: .transportUnavailable
            case .commandFailed: .commandFailed
            }
        }
        guard let error = error as? TmuxSurfaceControlError else {
            return .unavailable
        }
        return switch error {
        case .localTmuxNotFound: .transportUnavailable
        case .workerNotReady: .workerNotReady
        case .commandFailed: .commandFailed
        case .invalidSurfaceOutput: .invalidSurfaceOutput
        case .sessionIdentityMismatch: .sessionIdentityMismatch
        case let .temporaryPaneRetained(_, reason):
            closeFailureReason(for: reason)
        case .paneNotOwned: .paneNotOwned
        case .leasePaneMissing: .leasePaneMissing
        case .restoreFailed: .unavailable
        }
    }

    private func closeFailureReason(
        for reason: RetainedTemporaryPaneReason
    ) -> TmuxTemporaryPaneCloseFailureReason {
        switch reason {
        case .cancelled: .cancelled
        case .workerNotReady: .workerNotReady
        case .timedOut: .timedOut
        case .transportUnavailable: .transportUnavailable
        case .commandFailed: .commandFailed
        case .invalidSurfaceOutput: .invalidSurfaceOutput
        case .sessionIdentityMismatch: .sessionIdentityMismatch
        case .createdPaneNotCurrent, .unavailable: .unavailable
        }
    }

    private func restoreFailureReason(
        for error: Error
    ) -> TmuxOriginRestoreFailureReason {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if error is InventoryProcessTimeoutError {
            return .timedOut
        }
        if let error = error as? SSHMasterPoolError {
            return switch error {
            case .shuttingDown: .transportUnavailable
            case .commandFailed: .commandFailed
            }
        }
        guard let error = error as? TmuxSurfaceControlError else {
            return .unavailable
        }
        return switch error {
        case .localTmuxNotFound: .transportUnavailable
        case .workerNotReady: .workerNotReady
        case .commandFailed: .commandFailed
        case .invalidSurfaceOutput: .invalidSurfaceOutput
        case .sessionIdentityMismatch: .sessionIdentityMismatch
        case .restoreFailed: .originNotRestored
        case .temporaryPaneRetained, .paneNotOwned, .leasePaneMissing:
            .unavailable
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

private extension TmuxRoute {
    var conversationKey: TerminalConversationKey {
        TerminalConversationKey(
            terminalTarget: target,
            tmux: expectedIdentity
        )
    }
}

private actor TmuxSurfaceOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private struct Lane {
        var activeID: UUID?
        var waiters: [Waiter] = []
    }

    private var lanes: [TerminalConversationKey: Lane] = [:]

    func run<Value: Sendable>(
        for key: TerminalConversationKey,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = try await acquire(for: key)
        defer { release(id: id, for: key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(
        for key: TerminalConversationKey
    ) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var lane = lanes[key, default: Lane()]
                if lane.activeID == nil {
                    lane.activeID = id
                    lanes[key] = lane
                    continuation.resume(returning: id)
                } else {
                    lane.waiters.append(Waiter(
                        id: id,
                        continuation: continuation
                    ))
                    lanes[key] = lane
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id, for: key) }
        }
    }

    private func release(
        id: UUID,
        for key: TerminalConversationKey
    ) {
        guard var lane = lanes[key], lane.activeID == id else { return }
        guard !lane.waiters.isEmpty else {
            lanes[key] = nil
            return
        }
        let waiter = lane.waiters.removeFirst()
        lane.activeID = waiter.id
        lanes[key] = lane
        waiter.continuation.resume(returning: waiter.id)
    }

    private func cancel(
        id: UUID,
        for key: TerminalConversationKey
    ) {
        guard var lane = lanes[key] else { return }
        if lane.activeID == id {
            return
        }
        guard let index = lane.waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = lane.waiters.remove(at: index)
        lanes[key] = lane
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private struct TemporaryPaneKey: Hashable, Sendable {
    let conversationKey: TerminalConversationKey
    let paneID: String
}

private struct OwnedTemporaryPane: Sendable {
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
