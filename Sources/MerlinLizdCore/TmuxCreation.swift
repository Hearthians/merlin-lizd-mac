import Foundation

public enum TmuxCreationError: Error, Equatable, Sendable {
    case unavailable
    case invalidSessionName
    case invalidWorkingDirectory
}

public struct TmuxCreationDraft: Equatable, Sendable {
    public let title: String
    public let target: TerminalTarget
    public let suggestedSessionName: String

    public init(
        title: String,
        target: TerminalTarget,
        suggestedSessionName: String
    ) {
        self.title = title
        self.target = target
        self.suggestedSessionName = suggestedSessionName
    }
}

public struct TmuxLaunchConfiguration: Equatable, Sendable {
    public let sessionName: String
    public let workingDirectory: String?

    public init(sessionName: String, workingDirectory: String?) throws {
        let normalizedName = sessionName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard MerlinIdentifierValidator.isTmuxSessionName(normalizedName) else {
            throw TmuxCreationError.invalidSessionName
        }
        if
            let workingDirectory,
            !MerlinIdentifierValidator.isTmuxWorkingDirectory(workingDirectory)
        {
            throw TmuxCreationError.invalidWorkingDirectory
        }
        self.sessionName = normalizedName
        self.workingDirectory = workingDirectory
    }
}

public struct TmuxCreationResult: Equatable, Sendable {
    public let draft: TmuxCreationDraft
    public let configuration: TmuxLaunchConfiguration
}

public struct TmuxCreationCoordinator: Equatable, Sendable {
    public private(set) var pending: TmuxCreationDraft?

    public init() {}

    public mutating func request(_ draft: TmuxCreationDraft) {
        pending = draft
    }

    public mutating func cancel() {
        pending = nil
    }

    public mutating func create(
        sessionName: String,
        workingDirectory: String
    ) throws -> TmuxCreationResult {
        guard let pending else {
            throw TmuxCreationError.unavailable
        }
        let configuration = try TmuxLaunchConfiguration(
            sessionName: sessionName,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory
        )
        self.pending = nil
        return TmuxCreationResult(
            draft: pending,
            configuration: configuration
        )
    }
}
