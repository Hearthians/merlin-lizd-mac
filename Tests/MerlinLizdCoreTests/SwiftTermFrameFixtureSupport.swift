import Foundation
@testable import MerlinLizdCore

private enum SwiftTermFrameFixtureLoadingError: Error {
    case missing(String)
}

func fixture(named name: String) throws -> TerminalGridFrame {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/TerminalFrames"
    ) else {
        throw SwiftTermFrameFixtureLoadingError.missing(name)
    }
    return try JSONDecoder().decode(
        TerminalGridFrame.self,
        from: Data(contentsOf: url)
    )
}
