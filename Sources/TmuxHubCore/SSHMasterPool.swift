import Darwin
import Foundation

public enum SSHWarmupPriority: Int, Sendable {
    case background
    case foreground
}

public enum SSHReplayPolicy: Sendable {
    case readOnly
    case never
}

public enum SSHLinkState: Equatable, Sendable {
    case ready
    case failed
}

enum SSHMasterPoolError: Error, Equatable, Sendable {
    case commandFailed(exitCode: Int32)
    case connectionFailed(exitCode: Int32, message: String)
    case shuttingDown
}

/// Keep the diagnostic attached to the shared preparation result so concurrent
/// callers cannot accidentally receive a later attempt's failure.
private struct SSHPreparationResult: Sendable {
    let linkState: SSHLinkState
    let failure: SSHMasterPoolError?

    static let ready = SSHPreparationResult(linkState: .ready, failure: nil)
    static let failed = SSHPreparationResult(
        linkState: .failed,
        failure: .commandFailed(exitCode: 255)
    )

    static func failure(_ output: InventoryProcessOutput) -> SSHPreparationResult {
        SSHPreparationResult(linkState: .failed, failure: sshCommandFailure(output))
    }
}

private func sshCommandFailure(_ output: InventoryProcessOutput) -> SSHMasterPoolError {
    let message = sanitizedSSHDiagnostic(output.stderr)
    guard !message.isEmpty else {
        return .commandFailed(exitCode: output.exitCode)
    }
    return .connectionFailed(exitCode: output.exitCode, message: message)
}

private func sanitizedSSHDiagnostic(_ stderr: String) -> String {
    let filtered = String(String.UnicodeScalarView(stderr.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }))
    return String(filtered.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
}

public final class SSHMasterPool: @unchecked Sendable {
    private let commands: SSHMasterCommands
    private let runner: any InventoryProcessRunning
    private let state: SSHMasterPoolState
    private let shutdownCoordinator = SSHMasterShutdownCoordinator()
    private let managedOwnership: SSHManagedOwnershipRegistry
    private let passwordProvider: SSHPasswordProvider
    private let retryBoundaryHook: (@Sendable () async -> Void)?
    private let retryInvalidationHook: (@Sendable () async -> Void)?

    public convenience init(
        maxConcurrentPreparations: Int = 4,
        passwordProvider: @escaping SSHPasswordProvider = { _ in nil }
    ) {
        let directory = Self.defaultSocketDirectory()
        self.init(
            directory: directory,
            runner: FoundationInventoryProcessRunner(),
            maxConcurrentPreparations: maxConcurrentPreparations,
            passwordProvider: passwordProvider,
            retryBoundaryHook: nil,
            retryInvalidationHook: nil
        )
    }

    /// Keeps SSH control sockets below the Unix-domain path limit even on
    /// systems whose per-user temporary directory has a long sandboxed path.
    static func defaultSocketDirectory() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("tmuxhub-\(getuid())", isDirectory: true)
    }

    convenience init(
        testDirectory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int = 4,
        passwordProvider: @escaping SSHPasswordProvider = { _ in nil },
        retryBoundaryHook: (@Sendable () async -> Void)? = nil,
        retryInvalidationHook: (@Sendable () async -> Void)? = nil
    ) {
        self.init(
            directory: testDirectory,
            runner: runner,
            maxConcurrentPreparations: maxConcurrentPreparations,
            passwordProvider: passwordProvider,
            retryBoundaryHook: retryBoundaryHook,
            retryInvalidationHook: retryInvalidationHook
        )
    }

    private init(
        directory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int,
        passwordProvider: @escaping SSHPasswordProvider,
        retryBoundaryHook: (@Sendable () async -> Void)?,
        retryInvalidationHook: (@Sendable () async -> Void)?
    ) {
        precondition(maxConcurrentPreparations > 0)
        commands = SSHMasterCommands(directory: directory)
        managedOwnership = SSHManagedOwnershipRegistry(directory: directory)
        self.runner = runner
        self.passwordProvider = passwordProvider
        self.retryBoundaryHook = retryBoundaryHook
        self.retryInvalidationHook = retryInvalidationHook
        state = SSHMasterPoolState(
            directory: directory,
            commands: commands,
            runner: runner,
            maxConcurrentPreparations: maxConcurrentPreparations,
            passwordProvider: passwordProvider
        )
    }

    public func prepare(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHLinkState {
        guard (try? commands.socketPath(alias: alias)) != nil else {
            return .failed
        }
        return await state.prepare(alias: alias, priority: priority).linkState
    }

    public func managedCommand(
        _ command: CommandSpec,
        alias: String
    ) throws -> CommandSpec {
        try preparedMasterCommand(command, alias: alias)
    }

    /// Managed commands reuse a shared master when one is available and retain
    /// normal interactive SSH prompting otherwise. Saved-password lookup belongs
    /// exclusively to asynchronous master preparation so a Keychain request can
    /// never block terminal construction or another background command.
    private func preparedMasterCommand(
        _ command: CommandSpec,
        alias: String
    ) throws -> CommandSpec {
        let managed = try commands.managed(command, alias: alias)
        try managedOwnership.register(alias: alias)
        return managed
    }

    func run(
        _ command: CommandSpec,
        alias: String,
        replay: SSHReplayPolicy
    ) async throws -> InventoryProcessOutput {
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }
        let preparation = await state.prepare(alias: alias, priority: .foreground)
        guard preparation.linkState == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw preparation.failure ?? SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        let managed = try preparedMasterCommand(command, alias: alias)
        let output: InventoryProcessOutput?
        do {
            output = try await runAdmitted(managed)
        } catch {
            if error is CancellationError { throw error }
            guard replay == .readOnly else { throw error }
            output = nil
        }
        if output?.exitCode == 0, let output {
            return output
        }
        if let output, output.exitCode != 255 {
            return output
        }
        guard replay == .readOnly else {
            throw output.map(sshCommandFailure)
                ?? SSHMasterPoolError.commandFailed(exitCode: 255)
        }

        if let retryBoundaryHook {
            await retryBoundaryHook()
        }
        try Task.checkCancellation()
        await state.invalidate(alias: alias)
        if let retryInvalidationHook {
            await retryInvalidationHook()
        }
        try Task.checkCancellation()
        let retryPreparation = await state.prepare(alias: alias, priority: .foreground)
        guard retryPreparation.linkState == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw retryPreparation.failure ?? SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        try Task.checkCancellation()
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        try Task.checkCancellation()
        let replayed = try await runAdmitted(preparedMasterCommand(command, alias: alias))
        guard replayed.exitCode != 255 else {
            throw sshCommandFailure(replayed)
        }
        return replayed
    }

    func transfer(batchFile: URL, alias: String) async throws -> InventoryProcessOutput {
        try Task.checkCancellation()
        let preparation = await state.prepare(alias: alias, priority: .foreground)
        guard preparation.linkState == .ready else {
            throw preparation.failure ?? SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        // Never replay a file transfer automatically.
        return try await runAdmitted(commands.sftp(batchFile: batchFile, alias: alias))
    }

    /// Adds a forwarding request to the already prepared control master. A
    /// failed request is never replayed because OpenSSH may have accepted it
    /// before the client lost its response.
    func openLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async throws {
        let command = try commands.openLocalForward(
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        let preparation = await state.prepare(alias: alias, priority: .foreground)
        guard preparation.linkState == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw preparation.failure ?? SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        let output = try await runAdmitted(command)
        if output.exitCode == 255 {
            await state.invalidate(alias: alias)
        }
        guard output.exitCode == 0 else {
            let diagnostic = sanitizedSSHDiagnostic(output.stderr).lowercased()
            let muxBindFailure = "mux_client_forward: forwarding request failed: port forwarding failed"
            if diagnostic.contains("address already in use")
                || diagnostic.contains("cannot listen to port")
                || diagnostic.split(separator: "\n").contains(where: {
                    let line = $0.trimmingCharacters(in: .whitespaces)
                    return line == muxBindFailure || line == "\(muxBindFailure)."
                })
            {
                throw SSHLocalForwardingError.localPortUnavailable(localPort)
            }
            throw sshCommandFailure(output)
        }
    }

    /// Removes only the exact forwarding tuple owned by the caller. Cleanup is
    /// best effort and deliberately does not establish a missing master.
    func cancelLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async {
        guard let command = try? commands.cancelLocalForward(
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        ), !Task.isCancelled, !(await state.shuttingDown()) else { return }

        guard let output = try? await runAdmitted(command) else { return }
        if output.exitCode == 255 {
            await state.invalidate(alias: alias)
        }
    }

    /// Checks the exact control socket without starting a new connection.
    func isMasterRunning(alias: String) async -> Bool {
        guard let command = try? commands.check(alias: alias),
            !Task.isCancelled,
            !(await state.shuttingDown()),
            let output = try? await runAdmitted(command)
        else { return false }

        if output.exitCode == 255 {
            await state.invalidate(alias: alias)
        }
        return output.exitCode == 0
    }

    public func shutdown() async {
        managedOwnership.beginShutdown()
        let task = await shutdownCoordinator.task { [weak self] in
            await self?.performShutdown()
        }
        await task.value
    }

    private func performShutdown() async {
        let tasks = await state.beginShutdown()
        for task in tasks {
            _ = await task.value
        }
        let aliases = Set(await state.ownedAliasesForShutdown())
            .union(managedOwnership.aliasesForShutdown())
        for alias in aliases {
            guard let stop = try? commands.stop(alias: alias) else { continue }
            _ = try? await runner.run(stop)
            guard
                let check = try? commands.check(alias: alias),
                let output = try? await runner.run(check),
                output.exitCode != 0,
                let socketPath = try? commands.socketPath(alias: alias)
            else { continue }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    func waitUntilPreparationCountForTesting(_ count: Int) async {
        await state.waitUntilPreparationCount(count)
    }

    func waitUntilShuttingDownForTesting() async {
        await state.waitUntilShuttingDown()
    }

    func waitUntilShutdownIsWaitingForCommandsForTesting() async {
        await state.waitUntilShutdownIsWaitingForCommands()
    }

    func waitUntilPriorityForTesting(
        alias: String,
        priority: SSHWarmupPriority
    ) async {
        await state.waitUntilPriority(alias: alias, priority: priority)
    }

    func waitUntilShutdownCallerCountForTesting(_ count: Int) async {
        await shutdownCoordinator.waitUntilCallerCount(count)
    }

    private func runAdmitted(
        _ command: CommandSpec
    ) async throws -> InventoryProcessOutput {
        try Task.checkCancellation()
        guard await state.acquireCommandLease() else {
            throw SSHMasterPoolError.shuttingDown
        }
        do {
            try Task.checkCancellation()
            let output = try await runner.run(command)
            await state.releaseCommandLease()
            return output
        } catch {
            await state.releaseCommandLease()
            throw error
        }
    }
}

private final class SSHManagedOwnershipRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var aliases: Set<String> = []
    private var isShuttingDown = false
    private var directoryIsReady = false

    init(directory: URL) {
        self.directory = directory
    }

    func register(alias: String) throws {
        try lock.withLock {
            guard !isShuttingDown else {
                throw SSHMasterPoolError.shuttingDown
            }
            guard ensureDirectory() else {
                throw SSHMasterPoolError.commandFailed(exitCode: 255)
            }
            aliases.insert(alias)
        }
    }

    func beginShutdown() {
        lock.withLock { isShuttingDown = true }
    }

    func aliasesForShutdown() -> Set<String> {
        lock.withLock {
            let owned = aliases
            aliases.removeAll()
            return owned
        }
    }

    private func ensureDirectory() -> Bool {
        if directoryIsReady { return true }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch CocoaError.fileWriteFileExists {
            // Validate the existing path below.
        } catch {
            return false
        }

        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var information = stat()
        guard
            fstat(descriptor, &information) == 0,
            (information.st_mode & S_IFMT) == S_IFDIR,
            information.st_uid == getuid(),
            fchmod(descriptor, S_IRWXU) == 0
        else { return false }

        directoryIsReady = true
        return true
    }
}

private actor SSHMasterShutdownCoordinator {
    private var shutdownTask: Task<Void, Never>?
    private var callerCount = 0
    private var callerCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    func task(
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        callerCount += 1
        let satisfied = callerCountWaiters.filter { $0.0 <= callerCount }
        callerCountWaiters.removeAll { $0.0 <= callerCount }
        satisfied.forEach { $0.1.resume() }

        if let shutdownTask { return shutdownTask }
        let task = Task { await operation() }
        shutdownTask = task
        return task
    }

    func waitUntilCallerCount(_ count: Int) async {
        guard callerCount < count else { return }
        await withCheckedContinuation { continuation in
            callerCountWaiters.append((count, continuation))
        }
    }
}

private actor SSHMasterPoolState {
    private struct PreparationWaiter {
        let alias: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let directory: URL
    private let commands: SSHMasterCommands
    private let runner: any InventoryProcessRunning
    private let maxConcurrentPreparations: Int
    private let passwordProvider: SSHPasswordProvider

    private var readyAliases: Set<String> = []
    private var ownedAliases: Set<String> = []
    private var preparations: [String: Task<SSHPreparationResult, Never>] = [:]
    private var preparationPriorities: [String: SSHWarmupPriority] = [:]
    private var foregroundWaiters: [PreparationWaiter] = []
    private var backgroundWaiters: [PreparationWaiter] = []
    private var activePreparations = 0
    private var activeCommandLeases = 0
    private var isShuttingDown = false
    private var isWaitingForCommandLeases = false
    private var directoryIsReady = false
    private var preparationCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandLeaseDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandLeaseWaitObservers: [CheckedContinuation<Void, Never>] = []
    private var priorityWaiters: [
        (String, SSHWarmupPriority, CheckedContinuation<Void, Never>)
    ] = []

    init(
        directory: URL,
        commands: SSHMasterCommands,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int,
        passwordProvider: @escaping SSHPasswordProvider
    ) {
        self.directory = directory
        self.commands = commands
        self.runner = runner
        self.maxConcurrentPreparations = maxConcurrentPreparations
        self.passwordProvider = passwordProvider
    }

    func prepare(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHPreparationResult {
        guard !isShuttingDown else { return .failed }
        if let task = preparations[alias] {
            promotePreparationIfNeeded(alias: alias, priority: priority)
            return await task.value
        }

        preparationPriorities[alias] = priority
        let task = Task { await self.performPreparation(alias: alias, priority: priority) }
        preparations[alias] = task
        resumePreparationCountWaiters()
        return await task.value
    }

    func invalidate(alias: String) {
        readyAliases.remove(alias)
    }

    func shuttingDown() -> Bool {
        isShuttingDown
    }

    func beginShutdown() async -> [Task<SSHPreparationResult, Never>] {
        if !isShuttingDown {
            isShuttingDown = true
            shutdownWaiters.forEach { $0.resume() }
            shutdownWaiters.removeAll()
            let queued = foregroundWaiters + backgroundWaiters
            foregroundWaiters.removeAll()
            backgroundWaiters.removeAll()
            queued.forEach { $0.continuation.resume(returning: false) }
            preparationCountWaiters.forEach { $0.1.resume() }
            preparationCountWaiters.removeAll()
            priorityWaiters.forEach { $0.2.resume() }
            priorityWaiters.removeAll()
        }
        if activeCommandLeases > 0 {
            isWaitingForCommandLeases = true
            commandLeaseWaitObservers.forEach { $0.resume() }
            commandLeaseWaitObservers.removeAll()
            await withCheckedContinuation { continuation in
                commandLeaseDrainWaiters.append(continuation)
            }
        }
        return Array(preparations.values)
    }

    func ownedAliasesForShutdown() -> [String] {
        let aliases = Array(ownedAliases)
        readyAliases.removeAll()
        ownedAliases.removeAll()
        return aliases
    }

    func acquireCommandLease() -> Bool {
        guard !isShuttingDown else { return false }
        activeCommandLeases += 1
        return true
    }

    func releaseCommandLease() {
        precondition(activeCommandLeases > 0)
        activeCommandLeases -= 1
        guard activeCommandLeases == 0 else { return }
        isWaitingForCommandLeases = false
        commandLeaseDrainWaiters.forEach { $0.resume() }
        commandLeaseDrainWaiters.removeAll()
    }

    func waitUntilPreparationCount(_ count: Int) async {
        guard preparations.count < count else { return }
        await withCheckedContinuation { continuation in
            preparationCountWaiters.append((count, continuation))
        }
    }

    func waitUntilShuttingDown() async {
        guard !isShuttingDown else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    func waitUntilShutdownIsWaitingForCommands() async {
        guard !isWaitingForCommandLeases else { return }
        await withCheckedContinuation { continuation in
            commandLeaseWaitObservers.append(continuation)
        }
    }

    func waitUntilPriority(
        alias: String,
        priority: SSHWarmupPriority
    ) async {
        guard preparationPriorities[alias] != priority else { return }
        await withCheckedContinuation { continuation in
            priorityWaiters.append((alias, priority, continuation))
        }
    }

    private func performPreparation(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHPreparationResult {
        guard await acquireSlot(alias: alias, priority: priority) else {
            preparations.removeValue(forKey: alias)
            preparationPriorities.removeValue(forKey: alias)
            return .failed
        }

        let result = await establish(alias: alias)
        if result.linkState == .ready {
            readyAliases.insert(alias)
            ownedAliases.insert(alias)
        } else {
            readyAliases.remove(alias)
        }
        preparations.removeValue(forKey: alias)
        preparationPriorities.removeValue(forKey: alias)
        releaseSlot()
        return result
    }

    private func acquireSlot(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> Bool {
        guard !isShuttingDown else { return false }
        if activePreparations < maxConcurrentPreparations {
            activePreparations += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiter = PreparationWaiter(alias: alias, continuation: continuation)
            switch preparationPriorities[alias] ?? priority {
            case .foreground:
                foregroundWaiters.append(waiter)
            case .background:
                backgroundWaiters.append(waiter)
            }
        }
    }

    private func releaseSlot() {
        if isShuttingDown {
            activePreparations -= 1
            return
        }
        if !foregroundWaiters.isEmpty {
            foregroundWaiters.removeFirst().continuation.resume(returning: true)
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().continuation.resume(returning: true)
        } else {
            activePreparations -= 1
        }
    }

    private func establish(alias: String) async -> SSHPreparationResult {
        guard ensureDirectory() else { return .failed }
        guard let check = try? commands.check(alias: alias) else { return .failed }

        do {
            let output = try await runner.run(check)
            if output.exitCode == 0 {
                return .ready
            }
            if let socketPath = try? commands.socketPath(alias: alias) {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        } catch {
            // A thrown check did not prove that the socket is abandoned.
        }

        guard let prepare = try? commands.prepare(
            alias: alias,
            authentication: passwordProvider(alias)
        ) else { return .failed }
        do {
            let output = try await runner.run(prepare)
            return output.exitCode == 0 ? .ready : .failure(output)
        } catch {
            return .failed
        }
    }

    private func ensureDirectory() -> Bool {
        if directoryIsReady { return true }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch CocoaError.fileWriteFileExists {
            // Validate the existing path below.
        } catch {
            return false
        }

        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var information = stat()
        guard
            fstat(descriptor, &information) == 0,
            (information.st_mode & S_IFMT) == S_IFDIR,
            information.st_uid == getuid(),
            fchmod(descriptor, S_IRWXU) == 0
        else { return false }

        directoryIsReady = true
        return true
    }

    private func resumePreparationCountWaiters() {
        let satisfied = preparationCountWaiters.filter { $0.0 <= preparations.count }
        preparationCountWaiters.removeAll { $0.0 <= preparations.count }
        satisfied.forEach { $0.1.resume() }
    }

    private func promotePreparationIfNeeded(
        alias: String,
        priority: SSHWarmupPriority
    ) {
        guard
            priority == .foreground,
            preparationPriorities[alias] == .background
        else { return }
        preparationPriorities[alias] = .foreground
        if let index = backgroundWaiters.firstIndex(where: { $0.alias == alias }) {
            foregroundWaiters.append(backgroundWaiters.remove(at: index))
        }
        let satisfied = priorityWaiters.filter {
            $0.0 == alias && $0.1 == .foreground
        }
        priorityWaiters.removeAll { $0.0 == alias && $0.1 == .foreground }
        satisfied.forEach { $0.2.resume() }
    }
}
