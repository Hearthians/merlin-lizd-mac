import Foundation

/// The remote helper may request an editor path, never a local command or SSH destination.
public struct RemoteEditorRequest: Decodable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let token: String
    public let path: String
    public let isDirectory: Bool
    public let hostname: String
    public let serverAddress: String

    public static func decode(_ payload: String, expectedToken: String) -> Self? {
        let prefix = "tmuxhub-code;"
        guard payload.utf8.count <= 24_000, payload.hasPrefix(prefix),
            !expectedToken.isEmpty,
            let data = Data(base64Encoded: String(payload.dropFirst(prefix.count))),
            data.count <= 16_000,
            let request = try? JSONDecoder().decode(Self.self, from: data),
            request.version == 1, request.token == expectedToken,
            UUID(uuidString: request.requestID) != nil,
            request.path.hasPrefix("/"), request.path.utf8.count <= 8192,
            !request.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !request.hostname.isEmpty, request.hostname.utf8.count <= 255,
            request.hostname.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }),
            request.serverAddress.utf8.count <= 128,
            request.serverAddress.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") })
        else { return nil }
        return request
    }
}
