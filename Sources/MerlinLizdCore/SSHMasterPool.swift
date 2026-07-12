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

    public convenience init(maxConcurrentPreparations: Int = 4) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlz-ssh-\(getuid())", isDirectory: true)
        self.init(
            directory: directory,
            runner: FoundationInventoryProcessRunner(),
            maxConcurrentPreparations: maxConcurrentPreparations
        )
    }

    convenience init(
        testDirectory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int = 4
    ) {
        self.init(
            directory: testDirectory,
            runner: runner,
            maxConcurrentPreparations: maxConcurrentPreparations
        )
    }

    private init(
        directory: URL,
        runner: any InventoryProcessRunning,
        maxConcurrentPreparations: Int
    ) {
        precondition(maxConcurrentPreparations > 0)
        commands = SSHMasterCommands(directory: directory)
        self.runner = runner
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
        try commands.managed(command, alias: alias)
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
            output = try await runner.run(managed)
        } catch {
            if error is CancellationError { throw error }
            guard replay == .readOnly else { throw error }
            output = nil
        }
        if output?.exitCode == 0, let output {
            return output
        }
        if let output, output.exitCode != 255 {
            throw SSHMasterPoolError.commandFailed(exitCode: output.exitCode)
        }
        guard replay == .readOnly else {
            throw SSHMasterPoolError.commandFailed(exitCode: 255)
        }

        await state.invalidate(alias: alias)
        guard await prepare(alias: alias, priority: .foreground) == .ready else {
            if await state.shuttingDown() {
                throw SSHMasterPoolError.shuttingDown
            }
            throw SSHMasterPoolError.commandFailed(exitCode: 255)
        }
        if await state.shuttingDown() {
            throw SSHMasterPoolError.shuttingDown
        }

        let replayed = try await runner.run(managedCommand(command, alias: alias))
        guard replayed.exitCode == 0 else {
            throw SSHMasterPoolError.commandFailed(exitCode: replayed.exitCode)
        }
        return replayed
    }

    public func shutdown() async {
        let tasks = await state.beginShutdown()
        for task in tasks {
            _ = await task.value
        }
        let aliases = await state.readyAliasesForShutdown()
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
}

private actor SSHMasterPoolState {
    private struct PreparationWaiter {
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let directory: URL
    private let commands: SSHMasterCommands
    private let runner: any InventoryProcessRunning
    private let maxConcurrentPreparations: Int

    private var readyAliases: Set<String> = []
    private var preparations: [String: Task<SSHLinkState, Never>] = [:]
    private var foregroundWaiters: [PreparationWaiter] = []
    private var backgroundWaiters: [PreparationWaiter] = []
    private var activePreparations = 0
    private var isShuttingDown = false
    private var directoryIsReady = false
    private var preparationCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

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
            return await task.value
        }

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

    func beginShutdown() -> [Task<SSHLinkState, Never>] {
        guard !isShuttingDown else { return Array(preparations.values) }
        isShuttingDown = true
        shutdownWaiters.forEach { $0.resume() }
        shutdownWaiters.removeAll()
        let queued = foregroundWaiters + backgroundWaiters
        foregroundWaiters.removeAll()
        backgroundWaiters.removeAll()
        queued.forEach { $0.continuation.resume(returning: false) }
        preparationCountWaiters.forEach { $0.1.resume() }
        preparationCountWaiters.removeAll()
        return Array(preparations.values)
    }

    func readyAliasesForShutdown() -> [String] {
        let aliases = Array(readyAliases)
        readyAliases.removeAll()
        return aliases
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

    private func performPreparation(
        alias: String,
        priority: SSHWarmupPriority
    ) async -> SSHLinkState {
        guard await acquireSlot(priority: priority) else {
            preparations.removeValue(forKey: alias)
            return .failed
        }

        let result = await establish(alias: alias)
        if result == .ready {
            readyAliases.insert(alias)
        } else {
            readyAliases.remove(alias)
        }
        preparations.removeValue(forKey: alias)
        releaseSlot()
        return result
    }

    private func acquireSlot(priority: SSHWarmupPriority) async -> Bool {
        guard !isShuttingDown else { return false }
        if activePreparations < maxConcurrentPreparations {
            activePreparations += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiter = PreparationWaiter(continuation: continuation)
            switch priority {
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
}
