import Foundation

public enum MerlinTaskPageParserError: Error, Equatable, Sendable {
    case malformedResponse
}

/// Decodes only the approved fields required by the task list and telemetry
/// routing. Environment variables, storage paths, and tokens are intentionally
/// absent from the persisted projection.
public enum MerlinTaskPageParser {
    public static func parse(_ output: String) throws -> MerlinTaskPage {
        guard let data = output.data(using: .utf8) else {
            throw MerlinTaskPageParserError.malformedResponse
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MerlinTaskPageParserError.malformedResponse
        }

        let runs = response.list.compactMap(run(from:))
        return MerlinTaskPage(
            runs: runs,
            total: response.total,
            itemCount: response.list.count
        )
    }

    private static func run(from payload: Payload) -> MerlinTaskRun? {
        guard
            normalized(payload.triggerMode) == "manual",
            ["train", "dataprocessing"].contains(normalized(payload.jobType)),
            let status = status(for: payload.status)
        else {
            return nil
        }

        let id = payload.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = payload.meta?.caption?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let definitionName = payload.jobDefinitionName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let name: String
        if let caption, !caption.isEmpty {
            name = caption
        } else {
            name = definitionName
        }
        guard !id.isEmpty, !name.isEmpty else { return nil }
        let parameters = payload.meta?.jobRunParameters
        let metricRole = metricRole(from: parameters)
        return MerlinTaskRun(
            id: id,
            name: name,
            status: status,
            createdAtMilliseconds: payload.creationTime.value,
            startedAtMilliseconds: positive(payload.meta?.startRunningTime),
            completedAtMilliseconds: positive(payload.completedTime),
            totalRuntimeMilliseconds: positive(payload.meta?.totalRuntime),
            clusterName: nonempty(
                payload.meta?.jobRunParameters?.resource?
                    .arnoldConfiguration?.clusterName
            ),
            trialID: nonempty(payload.latestTrialID),
            metricRoleName: metricRole?.name,
            allocatedGPUCount: metricRole?.allocatedGPUCount,
            allocatedMemoryBytes: metricRole?.allocatedMemoryBytes,
            createdBy: nonempty(payload.createdBy),
            taskRoles: taskRoles(from: parameters)
        )
    }

    private static func taskRoles(
        from parameters: JobRunParameters?
    ) -> [MerlinTaskRole] {
        (parameters?.resource?.arnoldConfiguration?.roles ?? []).compactMap {
            MerlinTaskRole(
                name: $0.name,
                instanceCount: max(1, $0.count ?? 1)
            )
        }
    }

    private static func metricRole(
        from parameters: JobRunParameters?
    ) -> ResourceRole? {
        let roles = parameters?.resource?.arnoldConfiguration?.roles ?? []
        return roles.first {
            normalized($0.name) == "worker"
        } ?? roles.first {
            ($0.gpu ?? 0) > 0
        } ?? roles.first
    }

    private static func status(for status: String) -> MerlinTaskStatus? {
        switch normalized(status) {
        case "queued", "started", "running":
            MerlinTaskStatus(rawValue: normalized(status))
        case "failed":
            .failed
        case "done", "stopped", "disabled", "killed":
            MerlinTaskStatus(rawValue: normalized(status))
        default:
            nil
        }
    }

    private static func positive(_ value: FlexibleInt64?) -> Int64? {
        guard let value, value.value > 0 else { return nil }
        return value.value
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private struct Response: Decodable {
        let list: [Payload]
        let total: Int
    }

    private struct Payload: Decodable {
        let id: String
        let jobDefinitionName: String
        let status: String
        let jobType: String
        let triggerMode: String
        let createdBy: String?
        let creationTime: FlexibleInt64
        let completedTime: FlexibleInt64?
        let latestTrialID: String?
        let meta: Metadata?

        enum CodingKeys: String, CodingKey {
            case id
            case jobDefinitionName = "job_def_name"
            case status
            case jobType = "job_type"
            case triggerMode = "trigger_mode"
            case createdBy = "created_by"
            case creationTime = "creation_time"
            case completedTime = "completed_time"
            case latestTrialID = "latest_trial_id"
            case meta
        }
    }

    private struct Metadata: Decodable {
        let caption: String?
        let startRunningTime: FlexibleInt64?
        let totalRuntime: FlexibleInt64?
        let jobRunParameters: JobRunParameters?

        enum CodingKeys: String, CodingKey {
            case caption
            case startRunningTime = "start_running_time"
            case totalRuntime = "total_runtime_ms"
            case jobRunParameters = "job_run_params"
        }
    }

    private struct JobRunParameters: Decodable {
        let resource: ResourceConfiguration?
    }

    private struct ResourceConfiguration: Decodable {
        let arnoldConfiguration: ArnoldConfiguration?

        enum CodingKeys: String, CodingKey {
            case arnoldConfiguration = "arnold_config"
        }
    }

    private struct ArnoldConfiguration: Decodable {
        let clusterName: String?
        let roles: [ResourceRole]?
    }

    private struct ResourceRole: Decodable {
        let name: String
        let gpu: Int?
        let memoryMiB: FlexibleInt64?
        let count: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case gpu
            case memoryMiB = "memory"
            case count = "num"
        }

        var allocatedGPUCount: Int? {
            guard let gpu, gpu >= 0 else { return nil }
            let count = max(1, count ?? 1)
            let result = gpu.multipliedReportingOverflow(by: count)
            return result.overflow ? nil : result.partialValue
        }

        var allocatedMemoryBytes: UInt64? {
            guard let memoryMiB, memoryMiB.value > 0 else { return nil }
            let count = max(1, count ?? 1)
            guard
                let memory = UInt64(exactly: memoryMiB.value),
                let roleCount = UInt64(exactly: count)
            else { return nil }
            let totalMiB = memory.multipliedReportingOverflow(by: roleCount)
            guard !totalMiB.overflow else { return nil }
            let bytes = totalMiB.partialValue.multipliedReportingOverflow(
                by: 1_048_576
            )
            return bytes.overflow ? nil : bytes.partialValue
        }
    }

    private struct FlexibleInt64: Decodable {
        let value: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int64.self) {
                self.value = value
                return
            }
            let string = try container.decode(String.self)
            guard let value = Int64(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an integer or integer string"
                )
            }
            self.value = value
        }
    }
}
