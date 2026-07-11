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
    private let loader: InventoryLoader
    private var inFlightRefresh: Task<InventorySnapshot, Error>?

    public init(maxConcurrentProcesses: Int = 4) throws {
        guard maxConcurrentProcesses > 0 else {
            throw MerlinInventoryError.invalidConcurrencyLimit
        }
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        let processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: maxConcurrentProcesses,
            underlying: FoundationInventoryProcessRunner()
        )
        self.loader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            workerPageSize: 100,
            now: Date.init
        )
    }

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        workerPageSize: Int = 100,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard merlinCLIPath.hasPrefix("/") else {
            throw MerlinInventoryError.merlinCLIPathMustBeAbsolute
        }
        guard workerPageSize > 0 else {
            throw MerlinInventoryError.invalidWorkerPageSize
        }
        self.loader = InventoryLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            workerPageSize: workerPageSize,
            now: now
        )
    }

    /// Concurrent callers share one refresh. A later timer tick can start a new
    /// refresh only after the current one has completed.
    public func refresh(sshAliases: [String]) async throws -> InventorySnapshot {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        let loader = self.loader
        let task = Task {
            try await loader.load(sshAliases: sshAliases)
        }
        inFlightRefresh = task

        do {
            let snapshot = try await task.value
            inFlightRefresh = nil
            return snapshot
        } catch {
            inFlightRefresh = nil
            throw error
        }
    }
}

private struct InventoryLoader: Sendable {
    let merlinCLIPath: String
    let processRunner: any InventoryProcessRunning
    let workerPageSize: Int
    let now: @Sendable () -> Date

    func load(sshAliases: [String]) async throws -> InventorySnapshot {
        var devboxes: [Devbox] = []
        for role in ["OWNER", "SHARED"] {
            devboxes.append(contentsOf: try await loadDevboxes(accessRole: role))
        }

        var seen: Set<String> = []
        let unique = devboxes.filter { seen.insert($0.sid).inserted }
        let aliasesBySID = await resolveAliases(sshAliases)
        let inventory = await withTaskGroup(
            of: (Int, DevboxInventory).self,
            returning: [DevboxInventory].self
        ) { group in
            for (index, devbox) in unique.enumerated() {
                let alias = aliasesBySID[devbox.sid]
                group.addTask {
                    guard devbox.status.lowercased() == "running", let alias else {
                        return (index, DevboxInventory(devbox: devbox, sshAlias: alias))
                    }
                    return (index, await loadWorkers(for: devbox, alias: alias))
                }
            }
            var results: [(Int, DevboxInventory)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return InventorySnapshot(
            devboxes: inventory,
            refreshedAt: now()
        )
    }

    private func resolveAliases(_ aliases: [String]) async -> [String: String] {
        var result: [String: String] = [:]
        for alias in aliases where Self.isValidAlias(alias) {
            let command = CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: ["-G", alias]
            )
            guard
                let output = try? await processRunner.run(command),
                output.exitCode == 0,
                let sid = Self.devboxSID(fromSSHConfiguration: output.stdout),
                result[sid] == nil
            else {
                continue
            }
            result[sid] = alias
        }
        return result
    }

    private func loadWorkers(for devbox: Devbox, alias: String) async -> DevboxInventory {
        var offset = 0
        var workers: [WorkerInventoryRecord] = []

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
                output = try await processRunner.run(command)
            } catch {
                return DevboxInventory(
                    devbox: devbox,
                    sshAlias: alias,
                    workers: workers,
                    workerStatus: .failed(.transport)
                )
            }
            guard output.exitCode == 0 else {
                return DevboxInventory(
                    devbox: devbox,
                    sshAlias: alias,
                    workers: workers,
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
                    workers: workers,
                    workerStatus: .failed(.malformedOutput)
                )
            }
            workers.append(contentsOf: page.map(WorkerInventoryRecord.init(worker:)))
            guard page.count == workerPageSize else { break }
            offset += workerPageSize
        }

        return DevboxInventory(
            devbox: devbox,
            sshAlias: alias,
            workers: workers,
            workerStatus: .loaded
        )
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

    private static func isValidAlias(_ value: String) -> Bool {
        guard let match = value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) else {
            return false
        }
        return match == value.startIndex..<value.endIndex
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
