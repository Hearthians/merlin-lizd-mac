import Foundation

public actor MerlinTaskInventory {
    private struct InFlightRefresh {
        let generation: UUID
        let task: Task<Void, Never>
        var waiters: [
            UUID: CheckedContinuation<MerlinTaskSnapshot, Error>
        ]
    }

    private let loader: MerlinTaskLoader
    private var inFlightRefresh: InFlightRefresh?

    public init() throws {
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        loader = MerlinTaskLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: BoundedInventoryProcessRunner(
                maxConcurrentProcesses: 1,
                underlying: TimedInventoryProcessRunner(
                    timeout: .seconds(20),
                    underlying: FoundationInventoryProcessRunner()
                )
            ),
            now: Date.init
        )
    }

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard merlinCLIPath.hasPrefix("/") else {
            throw MerlinInventoryError.merlinCLIPathMustBeAbsolute
        }
        loader = MerlinTaskLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            now: now
        )
    }

    public func refresh() async throws -> MerlinTaskSnapshot {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    addWaiter(waiterID, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func addWaiter(
        _ waiterID: UUID,
        continuation: CheckedContinuation<MerlinTaskSnapshot, Error>
    ) {
        if var refresh = inFlightRefresh {
            refresh.waiters[waiterID] = continuation
            inFlightRefresh = refresh
            return
        }

        let generation = UUID()
        let loader = self.loader
        let task = Task {
            let result: Result<MerlinTaskSnapshot, Error>
            do {
                result = .success(try await loader.load())
            } catch {
                result = .failure(error)
            }
            self.completeRefresh(result, generation: generation)
        }
        inFlightRefresh = InFlightRefresh(
            generation: generation,
            task: task,
            waiters: [waiterID: continuation]
        )
    }

    private func completeRefresh(
        _ result: Result<MerlinTaskSnapshot, Error>,
        generation: UUID
    ) {
        guard
            let refresh = inFlightRefresh,
            refresh.generation == generation
        else { return }
        inFlightRefresh = nil
        for continuation in refresh.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard
            var refresh = inFlightRefresh,
            let continuation = refresh.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(throwing: CancellationError())
        if refresh.waiters.isEmpty {
            refresh.task.cancel()
            inFlightRefresh = nil
        } else {
            inFlightRefresh = refresh
        }
    }
}

private struct MerlinTaskLoader: Sendable {
    private static let pageSize = 100
    private static let maximumPageCount = 20

    let merlinCLIPath: String
    let processRunner: any InventoryProcessRunning
    let now: @Sendable () -> Date

    func load() async throws -> MerlinTaskSnapshot {
        var currentPage = 1
        var fetchedItemCount = 0
        var total = Int.max
        var runs: [MerlinTaskRun] = []

        while fetchedItemCount < total {
            try Task.checkCancellation()
            guard currentPage <= Self.maximumPageCount else {
                throw MerlinInventoryError.paginationLimitExceeded
            }
            let command = try listCommand(currentPage: currentPage)
            let output = try await processRunner.run(command)
            guard output.exitCode == 0 else {
                throw MerlinInventoryError.commandFailed(
                    exitCode: output.exitCode
                )
            }
            let page = try MerlinTaskPageParser.parse(output.stdout)
            total = page.total
            fetchedItemCount += page.itemCount
            runs.append(contentsOf: page.runs)

            guard page.itemCount == Self.pageSize else { break }
            currentPage += 1
        }

        var seen: Set<String> = []
        let unique = runs.filter { seen.insert($0.id).inserted }
        return MerlinTaskSnapshot.presenting(
            unique,
            refreshedAt: now(),
            historyLimit: 20
        )
    }

    private func listCommand(currentPage: Int) throws -> CommandSpec {
        let request = ListRequest(
            current: currentPage,
            pageSize: Self.pageSize
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        guard let body = String(data: data, encoding: .utf8) else {
            throw MerlinInventoryError.invalidRequest
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "job", "list-run",
                "--control-plane", "cn",
                "--json", body,
            ]
        )
    }
}

private struct ListRequest: Encodable {
    let current: Int
    let pageSize: Int
}
