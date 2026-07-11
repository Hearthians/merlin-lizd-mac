import Foundation

/// Runs the small set of Devbox mutations exposed by the app through the same
/// bounded, cancellation-aware process infrastructure used by inventory.
public actor MerlinDevboxLifecycle {
    private let merlinCLIPath: String
    private let processRunner: any InventoryProcessRunning

    public init(maxConcurrentProcesses: Int = 1) throws {
        guard maxConcurrentProcesses > 0 else {
            throw MerlinInventoryError.invalidConcurrencyLimit
        }
        merlinCLIPath = try MerlinCLIResolver.resolve()
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: maxConcurrentProcesses,
            underlying: FoundationInventoryProcessRunner()
        )
    }

    init(
        merlinCLIPath: String,
        maxConcurrentProcesses: Int = 1,
        processRunner: any InventoryProcessRunning
    ) throws {
        guard merlinCLIPath.hasPrefix("/") else {
            throw MerlinInventoryError.merlinCLIPathMustBeAbsolute
        }
        guard maxConcurrentProcesses > 0 else {
            throw MerlinInventoryError.invalidConcurrencyLimit
        }
        self.merlinCLIPath = merlinCLIPath
        self.processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: maxConcurrentProcesses,
            underlying: processRunner
        )
    }

    public func start(sid: String) async throws -> Int32 {
        let command = try MerlinCommands.startDevbox(
            merlinCLIPath: merlinCLIPath,
            sid: sid
        )
        return try await processRunner.run(command).exitCode
    }
}
