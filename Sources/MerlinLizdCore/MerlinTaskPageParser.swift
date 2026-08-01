import Foundation

public enum MerlinTaskPageParserError: Error, Equatable, Sendable {
    case malformedResponse
}

/// Decodes only the fields required by the task list. In particular, `meta`,
/// environment variables, storage paths, and tokens are intentionally absent.
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
        return MerlinTaskRun(
            id: id,
            name: name,
            status: status,
            createdAtMilliseconds: payload.creationTime.value,
            startedAtMilliseconds: positive(payload.meta?.startRunningTime),
            completedAtMilliseconds: positive(payload.completedTime),
            totalRuntimeMilliseconds: positive(payload.meta?.totalRuntime)
        )
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
        let creationTime: FlexibleInt64
        let completedTime: FlexibleInt64?
        let meta: Metadata?

        enum CodingKeys: String, CodingKey {
            case id
            case jobDefinitionName = "job_def_name"
            case status
            case jobType = "job_type"
            case triggerMode = "trigger_mode"
            case creationTime = "creation_time"
            case completedTime = "completed_time"
            case meta
        }
    }

    private struct Metadata: Decodable {
        let caption: String?
        let startRunningTime: FlexibleInt64?
        let totalRuntime: FlexibleInt64?

        enum CodingKeys: String, CodingKey {
            case caption
            case startRunningTime = "start_running_time"
            case totalRuntime = "total_runtime_ms"
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
