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
            devboxes: response.data,
            nextPageToken: token?.isEmpty == false ? token : nil
        )
    }

    private struct Response: Decodable {
        let responseBase: ResponseBase
        let data: [Devbox]
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
}
