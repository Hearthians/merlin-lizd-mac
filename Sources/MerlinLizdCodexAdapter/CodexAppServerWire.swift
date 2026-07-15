import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Non-finite JSON number"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Non-finite JSON number"
                    )
                )
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public enum JSONRPCID: Hashable, Sendable {
    case integer(Int64)
    case string(String)
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public enum CodexServerMessage: Equatable, Sendable {
    case notification(method: String, params: JSONValue?)
    case request(id: JSONRPCID, method: String, params: JSONValue?)
}

struct JSONRPCInboundEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
    }

    let jsonrpc: String?
    let id: JSONRPCID?
    let hasID: Bool
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let hasResult: Bool
    let error: ErrorBody?
    let hasError: Bool

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = container.contains(.jsonrpc)
            ? try container.decode(String.self, forKey: .jsonrpc)
            : nil
        hasID = container.contains(.id)
        id = hasID ? try container.decode(JSONRPCID.self, forKey: .id) : nil
        method = container.contains(.method)
            ? try container.decode(String.self, forKey: .method)
            : nil
        params = container.contains(.params)
            ? try container.decode(JSONValue.self, forKey: .params)
            : nil
        hasResult = container.contains(.result)
        result = hasResult
            ? try container.decode(JSONValue.self, forKey: .result)
            : nil
        hasError = container.contains(.error)
        error = hasError
            ? try container.decode(ErrorBody.self, forKey: .error)
            : nil
    }
}

struct JSONRPCRequestEnvelope: Encodable {
    let id: JSONRPCID
    let method: String
    let params: JSONValue?
}

struct JSONRPCNotificationEnvelope: Encodable {
    let method: String
    let params: JSONValue?
}

struct JSONRPCErrorResponseEnvelope: Encodable {
    struct Body: Encodable {
        let code: Int
        let message: String
    }

    let id: JSONRPCID
    let error: Body
}
