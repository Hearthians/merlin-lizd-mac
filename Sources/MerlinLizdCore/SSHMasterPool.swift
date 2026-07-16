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
    case shuttingDown
}

public final class SSHMasterPool: @unchecked Sendable {
    private let commands: SSHMasterCommands
    private let runner: any InventoryProcessRunning
    private let state: SSHMasterPoolState
    private let shutdownCoordinator = SSHMasterShutdownCoordinator()
    private let managedOwnership: SSHManagedOwnershipRegistry
    private let retryBoundaryHook: (@Sendable () async -> Void)?
    private let retryInvalidationHook: (@Sendable () async -> Void)?

    public convenience init(maxConcurrentPreparations: Int = 4) {
        let directory = Self.defaultSocketDirectory()
        self.init(
            directory: directory,
            runner: FoundationInventoryProcessRunner(),
            maxConcurrentPreparations: maxConcurrentPreparations,
            retryBoundaryHook: nil,
            retryInvalidationHook: nil
        )
    }

    /// Keeps SSH control sockets below the Unix-domain path limit even on
    /// systems whose per-user temporary directory has a long sandboxed path.
    static func defaultSocketDirectory() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("merlinhubx-ssh-\(getuid())", isDirectory: true)
    }

    convenience init(
        testDirectory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int = 4,
        retryBoundaryHook: (@Sendable () async -> Void)? = nil,
        retryInvalidationHook: (@Sendable () async -> Void)? = nil
    ) {
        self.init(
            directory: testDirectory,
            runner: runner,
            maxConcurrentPreparations: maxConcurrentPreparations,
            retryBoundaryHook: retryBoundaryHook,
            retryInvalidationHook: retryInvalidationHook
        )
    }

    private init(
        directory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int,
        retryBoundaryHook: (@Sendable () async -> Void)?,
        retryInvalidationHook: (@Sendable () async -> Void)?
    ) {
        precondition(maxConcurrentPreparations > 0)
        commands = SSHMasterCommands(directory: directory)
        managedOwnership = SSHManagedOwnershipRegistry(directory: directory)
        self.runner = runner
        self.retryBoundaryHook = retryBoundaryHook
        self.retryInvalidationHook = retryInvalidationHook
        state = SSHMasterPoolState(
            directory: directory,
            commands: commands,
            runner: runner,
            maxConcurrentPreparations: maxConcurrentPreparations
        )
    }

    public func prepare(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHLinkState {
        guard (try? commands.socketPath(alias: alias)) != nil else {
            return .failed
        }
        return await state.prepare(alias: alias, priority: priority)
    }

    public func managedCommand(
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
        guard await prepare(alias: alias, priority: .foreground) == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        let managed = try managedCommand(command, alias: alias)
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
            throw SSHMasterPoolError.commandFailed(exitCode: 255)
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
        guard await prepare(alias: alias, priority: .foreground) == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        try Task.checkCancellation()
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        try Task.checkCancellation()
        let replayed = try await runAdmitted(managedCommand(command, alias: alias))
        guard replayed.exitCode != 255 else {
            throw SSHMasterPoolError.commandFailed(exitCode: replayed.exitCode)
        }
        return replayed
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

    private var readyAliases: Set<String> = []
    private var ownedAliases: Set<String> = []
    private var preparations: [String: Task<SSHLinkState, Never>] = [:]
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
        maxConcurrentPreparations: Int
    ) {
        self.directory = directory
        self.commands = commands
        self.runner = runner
        self.maxConcurrentPreparations = maxConcurrentPreparations
    }

    func prepare(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHLinkState {
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

    func beginShutdown() async -> [Task<SSHLinkState, Never>] {
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
    ) async -> SSHLinkState {
        guard await acquireSlot(alias: alias, priority: priority) else {
            preparations.removeValue(forKey: alias)
            preparationPriorities.removeValue(forKey: alias)
            return .failed
        }

        let result = await establish(alias: alias)
        if result == .ready {
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

    private func establish(alias: String) async -> SSHLinkState {
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

        guard let prepare = try? commands.prepare(alias: alias) else { return .failed }
        do {
            let output = try await runner.run(prepare)
            return output.exitCode == 0 ? .ready : .failed
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
