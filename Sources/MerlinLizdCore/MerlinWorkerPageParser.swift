import Foundation

public struct MerlinWorkerPage: Equatable, Sendable {
    public let workers: [Worker]
    public let nextPageToken: String?

    public init(workers: [Worker], nextPageToken: String?) {
        self.workers = workers
        self.nextPageToken = nextPageToken
    }
}

public enum MerlinWorkerPageParserError: Error, Equatable, Sendable {
    case malformedResponse
    case server(code: Int, message: String)
    case invalidWorkerSID(String)
    case invalidResources(workerSID: String)
}

/// Parses the safe subset of `merlin-cli cpu-devbox workers list` output.
/// A validated SSH proxy destination is retained for direct Worker access;
/// Pod/host addresses, signed webshell URLs, and Grafana URLs remain excluded.
public enum MerlinWorkerPageParser {
    private static let bytesPerGiB: UInt64 = 1_073_741_824

    public static func parse(_ output: String) throws -> MerlinWorkerPage {
        guard let data = output.data(using: .utf8) else {
            throw MerlinWorkerPageParserError.malformedResponse
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MerlinWorkerPageParserError.malformedResponse
        }
        guard response.responseBase.code == 0 else {
            throw MerlinWorkerPageParserError.server(
                code: response.responseBase.code,
                message: response.responseBase.message
            )
        }

        let workers = try response.data.map(worker(from:))
        let rawToken = response.pagination.nextPageToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MerlinWorkerPage(
            workers: workers,
            nextPageToken: rawToken?.isEmpty == false ? rawToken : nil
        )
    }

    private static func worker(from payload: WorkerPayload) throws -> Worker {
        let prefix = "wkr_"
        guard payload.sid.hasPrefix(prefix) else {
            throw MerlinWorkerPageParserError.invalidWorkerSID(payload.sid)
        }
        let numericID = String(payload.sid.dropFirst(prefix.count))
        guard MerlinIdentifierValidator.isWorkerID(numericID) else {
            throw MerlinWorkerPageParserError.invalidWorkerSID(payload.sid)
        }
        guard
            payload.cpuCores >= 0,
            payload.gpuCount >= 0,
            let memoryGiB = Int(exactly: payload.memoryBytes / bytesPerGiB)
        else {
            throw MerlinWorkerPageParserError.invalidResources(
                workerSID: payload.sid
            )
        }

        let rawStatus = payload.status.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rawClusterName = payload.clusterName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let sshProxyDestination = payload.sshProxyCommand.flatMap { value in
            MerlinIdentifierValidator.isWorkerSSHProxyDestination(
                value,
                workerID: numericID
            ) ? value : nil
        }
        return Worker(
            id: numericID,
            cpuCores: payload.cpuCores,
            memoryGiB: memoryGiB,
            gpuCount: payload.gpuCount,
            gpuType: payload.gpuType,
            clusterName: rawClusterName?.isEmpty == false
                ? rawClusterName
                : nil,
            platformStatus: rawStatus.isEmpty ? nil : rawStatus,
            sshProxyDestination: sshProxyDestination,
            podIP: nil,
            port: 0,
            createdAt: payload.createdAt,
            webshellURL: nil,
            readiness: .listed
        )
    }

    private struct Response: Decodable {
        let responseBase: ResponseBase
        let data: [WorkerPayload]
        let pagination: Pagination

        enum CodingKeys: String, CodingKey {
            case responseBase = "ResponseBase"
            case data
            case pagination
        }
    }

    private struct ResponseBase: Decodable {
        let code: Int
        let message: String
    }

    private struct Pagination: Decodable {
        let nextPageToken: String?

        enum CodingKeys: String, CodingKey {
            case nextPageToken = "next_page_token"
        }
    }

    private struct WorkerPayload: Decodable {
        let sid: String
        let status: String
        let gpuCount: Int
        let cpuCores: Int
        let memoryBytes: UInt64
        let gpuType: String?
        let clusterName: String?
        let createdAt: String
        let sshProxyCommand: String?

        enum CodingKeys: String, CodingKey {
            case sid
            case status
            case gpuCount = "gpu_count"
            case cpuCores = "cpu_cores"
            case memoryBytes = "memory_bytes"
            case gpuType = "gpu_type"
            case clusterName = "cluster"
            case createdAt = "created_at"
            case sshProxyCommand = "ssh_proxy_cmd"
        }
    }
}
