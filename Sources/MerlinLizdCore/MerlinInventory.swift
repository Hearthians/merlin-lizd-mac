import Foundation

public enum MerlinInventoryError: Error, Equatable, Sendable {
    case merlinCLIPathMustBeAbsolute
    case merlinCLINotFound
    case invalidConcurrencyLimit
    case invalidWorkerPageSize
    case commandFailed(exitCode: Int32)
    case invalidRequest
}

public actor MerlinInventory {
    private struct InFlightRefresh {
        let generation: UUID
        let task: Task<InventorySnapshot, Error>
    }

    private let loader: InventoryLoader
    private let workerLoader: InventoryLoader
    private var inFlightRefresh: InFlightRefresh?

    public init(
        sshMasterPool: SSHMasterPool,
        maxConcurrentProcesses: Int = 4
    ) throws {
        guard maxConcurrentProcesses > 0 else {
            throw MerlinInventoryError.invalidConcurrencyLimit
        }
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        let processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 2,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(20),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        let workerProcessRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: maxConcurrentProcesses,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(45),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        self.loader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            workerPageSize: 100,
            loadDevboxRolesConcurrently: true,
            now: Date.init,
            sshMasterPool: sshMasterPool,
            pooledExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .seconds(20)
            )
        )
        self.workerLoader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: workerProcessRunner,
            workerPageSize: 100,
            loadDevboxRolesConcurrently: true,
            now: Date.init,
            sshMasterPool: sshMasterPool,
            pooledExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: maxConcurrentProcesses,
                timeout: .seconds(45)
            )
        )
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        workerPageSize: Int = 100,
        loadDevboxRolesConcurrently: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard merlinCLIPath.hasPrefix("/") else {
            throw MerlinInventoryError.merlinCLIPathMustBeAbsolute
        }
        guard (1 ... 100).contains(workerPageSize) else {
            throw MerlinInventoryError.invalidWorkerPageSize
        }
        self.loader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            workerPageSize: workerPageSize,
            loadDevboxRolesConcurrently: loadDevboxRolesConcurrently,
            now: now,
            sshMasterPool: sshMasterPool,
            pooledExecutionPolicy: nil
        )
        self.workerLoader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            workerPageSize: workerPageSize,
            loadDevboxRolesConcurrently: loadDevboxRolesConcurrently,
            now: now,
            sshMasterPool: sshMasterPool,
            pooledExecutionPolicy: nil
        )
    }

    /// Concurrent callers share one refresh. A later timer tick can start a new
    /// refresh only after the current one has completed.
    public func refresh(sshAliases: [String]) async throws -> InventorySnapshot {
        if let inFlightRefresh {
            return try await inFlightRefresh.task.value
        }

        let loader = self.loader
        let generation = UUID()
        let task = Task {
            try await loader.load(sshAliases: sshAliases)
        }
        inFlightRefresh = InFlightRefresh(generation: generation, task: task)

        do {
            let snapshot = try await task.value
            clearRefresh(generation: generation)
            return snapshot
        } catch {
            clearRefresh(generation: generation)
            throw error
        }
    }

    /// Readiness is intentionally separate from inventory refresh: entering a
    /// Worker can spend several seconds in mlx setup, so callers can display
    /// the machine tree first and merge this result in the background.
    public func probeWorker(
        sshAlias: String,
        workerID: String
    ) async -> WorkerReadiness {
        guard
            MerlinIdentifierValidator.isSSHAlias(sshAlias),
            MerlinIdentifierValidator.isWorkerID(workerID)
        else {
            return .unreachable
        }
        return await workerLoader.probeWorkerReadiness(
            workerID: workerID,
            alias: sshAlias
        )
    }

    /// Worker listing is isolated from Devbox inventory. Merlin's control plane
    /// is authoritative; SSH/`mlx` is used only when that command is unavailable
    /// and a validated alias provides a fallback route.
    public func loadWorkers(
        for devbox: Devbox,
        sshAlias: String?
    ) async -> DevboxInventory {
        let safeAlias = sshAlias.flatMap {
            MerlinIdentifierValidator.isSSHAlias($0) ? $0 : nil
        }
        guard devbox.status.isRunning else {
            return DevboxInventory(devbox: devbox, sshAlias: safeAlias)
        }
        return await workerLoader.loadWorkers(for: devbox, alias: safeAlias)
    }

    private func clearRefresh(generation: UUID) {
        // Keep cleanup tied to the task that installed the slot. This remains
        // safe if refresh sharing later gains additional cleanup paths.
        guard inFlightRefresh?.generation == generation else {
            return
        }
        inFlightRefresh = nil
    }
}

private enum WorkerInventoryLoadError: Error {
    case transport
    case commandFailed(exitCode: Int32)
    case malformedOutput

    var inventoryFailure: InventoryFailure {
        switch self {
        case .transport:
            .transport
        case let .commandFailed(exitCode):
            .commandFailed(exitCode: exitCode)
        case .malformedOutput:
            .malformedOutput
        }
    }
}

private struct InventoryLoader: Sendable {
    let merlinCLIPath: String
    let processRunner: any InventoryProcessRunning
    let workerPageSize: Int
    let loadDevboxRolesConcurrently: Bool
    let now: @Sendable () -> Date
    let sshMasterPool: SSHMasterPool?
    let pooledExecutionPolicy: BoundedAsyncOperationRunner?

    func load(sshAliases: [String]) async throws -> InventorySnapshot {
        let devboxes: [Devbox]
        if loadDevboxRolesConcurrently {
            async let owner = loadDevboxes(accessRole: "OWNER")
            async let shared = loadDevboxes(accessRole: "SHARED")
            devboxes = try await owner + shared
        } else {
            var sequential: [Devbox] = []
            for role in ["OWNER", "SHARED"] {
                sequential.append(contentsOf: try await loadDevboxes(accessRole: role))
            }
            devboxes = sequential
        }

        var seen: Set<String> = []
        let unique = devboxes.filter { seen.insert($0.sid).inserted }
        let aliasesBySID = await resolveAliases(sshAliases, devboxes: unique)
        let inventory = unique.map { devbox in
            DevboxInventory(
                devbox: devbox,
                sshAlias: aliasesBySID[devbox.sid]
            )
        }
        return InventorySnapshot(
            devboxes: inventory,
            refreshedAt: now()
        )
    }

    private func resolveAliases(
        _ aliases: [String],
        devboxes: [Devbox]
    ) async -> [String: String] {
        var result: [String: String] = [:]
        let knownSIDs = Set(devboxes.map(\.sid))
        let devboxesByNormalizedName = Dictionary(
            grouping: devboxes,
            by: { $0.name.lowercased() }
        )

        for alias in aliases where MerlinIdentifierValidator.isSSHAlias(alias) {
            let command = CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: ["-G", alias]
            )
            guard
                let output = try? await processRunner.run(command),
                output.exitCode == 0
            else {
                continue
            }

            if
                let sid = Self.devboxSID(fromSSHConfiguration: output.stdout),
                knownSIDs.contains(sid),
                result[sid] == nil
            {
                result[sid] = alias
                continue
            }

            // Some SSH aliases do not encode the Devbox SID in `User`. Fall
            // back only when the alias exactly names one unique Devbox, so a
            // broad SSH config entry cannot silently route the wrong machine.
            let nameMatches = devboxesByNormalizedName[alias.lowercased()] ?? []
            if
                nameMatches.count == 1,
                let sid = nameMatches.first?.sid,
                result[sid] == nil
            {
                result[sid] = alias
            }
        }
        return result
    }

    func loadWorkers(for devbox: Devbox, alias: String?) async -> DevboxInventory {
        do {
            let workers = try await loadWorkersFromMerlinCLI(
                instanceSID: devbox.sid
            )
            let authoritativeWorkers = workers.map(WorkerInventoryRecord.init(worker:))
            let enrichedWorkers: [WorkerInventoryRecord]
            if
                authoritativeWorkers.contains(where: {
                    $0.gpuCount > 0 && $0.gpuType == nil
                }),
                let alias
            {
                let supplemental = await loadWorkersThroughSSH(
                    for: devbox,
                    alias: alias
                )
                enrichedWorkers = Self.enrichingMissingGPUTypes(
                    in: authoritativeWorkers,
                    from: supplemental
                )
            } else {
                enrichedWorkers = authoritativeWorkers
            }
            return DevboxInventory(
                devbox: devbox,
                sshAlias: alias,
                workers: enrichedWorkers,
                workerStatus: .loaded
            )
        } catch let error as WorkerInventoryLoadError {
            guard let alias else {
                return DevboxInventory(
                    devbox: devbox,
                    workerStatus: .failed(error.inventoryFailure)
                )
            }
            return await loadWorkersThroughSSH(for: devbox, alias: alias)
        } catch {
            guard let alias else {
                return DevboxInventory(
                    devbox: devbox,
                    workerStatus: .failed(.transport)
                )
            }
            return await loadWorkersThroughSSH(for: devbox, alias: alias)
        }
    }

    private static func enrichingMissingGPUTypes(
        in authoritative: [WorkerInventoryRecord],
        from supplemental: DevboxInventory
    ) -> [WorkerInventoryRecord] {
        guard supplemental.workerStatus == .loaded else {
            return authoritative
        }
        var gpuTypesByWorkerID: [String: String] = [:]
        for worker in supplemental.workers {
            guard let gpuType = worker.gpuType else { continue }
            gpuTypesByWorkerID[worker.id] = gpuType
        }
        return authoritative.map { worker in
            guard
                worker.gpuCount > 0,
                worker.gpuType == nil,
                let gpuType = gpuTypesByWorkerID[worker.id]
            else {
                return worker
            }
            return worker.withGPUType(gpuType)
        }
    }

    private func loadWorkersFromMerlinCLI(
        instanceSID: String
    ) async throws -> [Worker] {
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var workers: [Worker] = []

        repeat {
            let command: CommandSpec
            do {
                command = try MerlinCommands.listWorkers(
                    merlinCLIPath: merlinCLIPath,
                    instanceSID: instanceSID,
                    pageSize: workerPageSize,
                    pageToken: pageToken
                )
            } catch {
                throw WorkerInventoryLoadError.malformedOutput
            }

            let output: InventoryProcessOutput
            do {
                output = try await processRunner.run(command)
            } catch {
                throw WorkerInventoryLoadError.transport
            }
            guard output.exitCode == 0 else {
                throw WorkerInventoryLoadError.commandFailed(
                    exitCode: output.exitCode
                )
            }

            let page: MerlinWorkerPage
            do {
                page = try MerlinWorkerPageParser.parse(output.stdout)
            } catch {
                throw WorkerInventoryLoadError.malformedOutput
            }
            workers.append(contentsOf: page.workers)
            pageToken = page.nextPageToken
            if let pageToken, !seenPageTokens.insert(pageToken).inserted {
                throw WorkerInventoryLoadError.malformedOutput
            }
        } while pageToken != nil

        return workers
    }

    private func loadWorkersThroughSSH(
        for devbox: Devbox,
        alias: String
    ) async -> DevboxInventory {
        var offset = 0
        var workers: [Worker] = []

        while true {
            let command = CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-nT",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    alias,
                    "NO_COLOR=1 TERM=dumb mlx worker list --limit \(workerPageSize) --offset \(offset)",
                ]
            )

            let output: InventoryProcessOutput
            do {
                if let sshMasterPool {
                    if let pooledExecutionPolicy {
                        output = try await pooledExecutionPolicy.run {
                            try await sshMasterPool.run(
                                command,
                                alias: alias,
                                replay: .readOnly
                            )
                        }
                    } else {
                        output = try await sshMasterPool.run(
                            command,
                            alias: alias,
                            replay: .readOnly
                        )
                    }
                } else {
                    output = try await processRunner.run(command)
                }
            } catch {
                return DevboxInventory(
                    devbox: devbox,
                    sshAlias: alias,
                    workers: workers.map(WorkerInventoryRecord.init(worker:)),
                    workerStatus: .failed(.transport)
                )
            }
            guard output.exitCode == 0 else {
                return DevboxInventory(
                    devbox: devbox,
                    sshAlias: alias,
                    workers: workers.map(WorkerInventoryRecord.init(worker:)),
                    workerStatus: .failed(.commandFailed(exitCode: output.exitCode))
                )
            }

            let page: [Worker]
            do {
                page = try WorkerListParser.parse(output.stdout)
            } catch {
                return DevboxInventory(
                    devbox: devbox,
                    sshAlias: alias,
                    workers: workers.map(WorkerInventoryRecord.init(worker:)),
                    workerStatus: .failed(.malformedOutput)
                )
            }
            workers.append(contentsOf: page)
            guard page.count == workerPageSize else { break }
            offset += workerPageSize
        }

        return DevboxInventory(
            devbox: devbox,
            sshAlias: alias,
            workers: workers.map(WorkerInventoryRecord.init(worker:)),
            workerStatus: .loaded
        )
    }

    func probeWorkerReadiness(
        workerID: String,
        alias: String
    ) async -> WorkerReadiness {
        let command = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-nT",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                alias,
                "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- true",
            ]
        )
        do {
            let output: InventoryProcessOutput
            if let sshMasterPool {
                if let pooledExecutionPolicy {
                    output = try await pooledExecutionPolicy.run {
                        try await sshMasterPool.run(
                            command,
                            alias: alias,
                            replay: .readOnly
                        )
                    }
                } else {
                    output = try await sshMasterPool.run(
                        command,
                        alias: alias,
                        replay: .readOnly
                    )
                }
            } else {
                output = try await processRunner.run(command)
            }
            let evidence = (output.stdout + "\n" + output.stderr).lowercased()
            if evidence.contains("worker has not been ready")
                || evidence.contains("worker is not ready")
            {
                return .notReady
            }
            return output.exitCode == 0 ? .ready : .unreachable
        } catch {
            return .unreachable
        }
    }

    private func loadDevboxes(accessRole: String) async throws -> [Devbox] {
        var result: [Devbox] = []
        var pageToken: String?

        repeat {
            let command = try devboxListCommand(
                accessRole: accessRole,
                pageToken: pageToken
            )
            let output = try await processRunner.run(command)
            guard output.exitCode == 0 else {
                throw MerlinInventoryError.commandFailed(exitCode: output.exitCode)
            }
            let page = try DevboxPageParser.parse(output.stdout)
            result.append(contentsOf: page.devboxes)
            pageToken = page.nextPageToken
        } while pageToken != nil

        return result
    }

    private func devboxListCommand(
        accessRole: String,
        pageToken: String?
    ) throws -> CommandSpec {
        let request = DevboxListRequest(
            filter: .init(accessRole: accessRole),
            pageSize: 100,
            pageToken: pageToken
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
                "cpu-devbox", "instances", "list",
                "--control-plane", "cn",
                "--json", body,
            ]
        )
    }

    private static func devboxSID(fromSSHConfiguration output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \Character.isWhitespace
            )
            guard fields.count == 2, fields[0].lowercased() == "user" else {
                continue
            }
            let user = fields[1]
            let digits = user.prefix(while: \Character.isNumber)
            guard !digits.isEmpty else { return nil }
            let suffix = user.dropFirst(digits.count)
            guard suffix.isEmpty || suffix.first == "." else { return nil }
            return "dbx_\(digits)"
        }
        return nil
    }
}

private struct DevboxListRequest: Encodable {
    struct Filter: Encodable {
        let accessRole: String

        enum CodingKeys: String, CodingKey {
            case accessRole = "access_role"
        }
    }

    let filter: Filter
    let pageSize: Int
    let pageToken: String?

    enum CodingKeys: String, CodingKey {
        case filter
        case pageSize = "page_size"
        case pageToken = "page_token"
    }
}
