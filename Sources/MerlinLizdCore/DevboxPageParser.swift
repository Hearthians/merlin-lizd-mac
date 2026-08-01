import Foundation

public enum DevboxPageParserError: Error, Equatable, Sendable {
    case invalidEncoding
    case server(code: Int, message: String)
}

public enum DevboxPageParser {
    public static func parse(_ output: String) throws -> DevboxPage {
        guard let data = output.data(using: .utf8) else {
            throw DevboxPageParserError.invalidEncoding
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.responseBase.code == 0 else {
            throw DevboxPageParserError.server(
                code: response.responseBase.code,
                message: response.responseBase.message
            )
        }
        let token = response.pagination.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DevboxPage(
            devboxes: response.data.map { payload in
                let destination = payload.sshProxyDestination.flatMap { value in
                    MerlinIdentifierValidator.isDevboxSSHProxyDestination(
                        value,
                        devboxSID: payload.sid
                    ) ? value : nil
                }
                return Devbox(
                    sid: payload.sid,
                    name: payload.name,
                    status: payload.status,
                    cpuCores: payload.cpuCores,
                    memoryBytes: payload.memoryBytes,
                    diskBytes: payload.diskBytes,
                    workerCount: payload.workerCount,
                    rootfsType: payload.rootfsType,
                    region: payload.region,
                    cluster: payload.cluster,
                    accessRole: payload.accessRole,
                    sshProxyDestination: destination,
                    createdAt: payload.createdAt,
                    updatedAt: payload.updatedAt
                )
            },
            nextPageToken: token?.isEmpty == false ? token : nil
        )
    }

    private struct Response: Decodable {
        let responseBase: ResponseBase
        let data: [DevboxPayload]
        let pagination: Pagination

        enum CodingKeys: String, CodingKey {
            case responseBase = "ResponseBase"
            case data
            case pagination
        }
    }

    private struct DevboxPayload: Decodable {
        let sid: String
        let name: String
        let status: DevboxLifecycle
        let cpuCores: Int?
        let memoryBytes: Int64?
        let diskBytes: Int64?
        let workerCount: Int?
        let rootfsType: String?
        let region: String?
        let cluster: DevboxCluster?
        let accessRole: String?
        let sshProxyDestination: String?
        let createdAt: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case sid
            case name
            case status
            case cpuCores = "cpu_cores"
            case memoryBytes = "memory_bytes"
            case diskBytes = "disk_bytes"
            case workerCount = "worker_num"
            case rootfsType = "rootfs_type"
            case region
            case cluster
            case accessRole = "access_role"
            case sshProxyDestination = "ssh_proxy_cmd"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
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
}
