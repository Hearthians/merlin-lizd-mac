import Foundation
@testable import MerlinLizdCore

func encodeRetainedTemporaryPaneReason(
    _ reason: RetainedTemporaryPaneReason
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(reason), as: UTF8.self)
}

func decodeRetainedTemporaryPaneReason(
    _ encoded: String
) throws -> RetainedTemporaryPaneReason {
    try JSONDecoder().decode(
        RetainedTemporaryPaneReason.self,
        from: Data(encoded.utf8)
    )
}
