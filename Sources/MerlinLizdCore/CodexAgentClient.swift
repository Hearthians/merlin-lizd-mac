public enum AgentAvailability: Equatable, Sendable {
    case ready
    case starting
    case unsupportedVersion(String)
    case authenticationRequired
    case capabilityUnavailable(String)
    case overloaded
    case crashed
    case stopped
}

public enum AgentMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct AgentMessage: Codable, Equatable, Sendable {
    public let role: AgentMessageRole
    public let text: String

    public init(role: AgentMessageRole, text: String) {
        self.role = role
        self.text = text
    }
}

public enum AgentFailure: Equatable, Sendable {
    case authenticationRequired
    case overloaded
    case capabilityUnavailable
    case interrupted
    case crashed
    case protocolFailure
}

public enum AgentEvent: Equatable, Sendable {
    case history([AgentMessage])
    case turnStarted(AgentTurnID)
    case userMessage(String)
    case assistantMessageDelta(String)
    case assistantMessageCompleted(String)
    case turnCompleted(AgentTurnID)
    case turnFailed(AgentTurnID?, AgentFailure)
}

public protocol CodexAgentClient: Sendable {
    func startThread() async throws -> AgentThreadID
    func resumeThread(_ threadID: AgentThreadID) async throws
    func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) async throws -> AgentTurnID
    func steerTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        prompt: String
    ) async throws
    func interruptTurn(threadID: AgentThreadID, turnID: AgentTurnID) async
    func events(for threadID: AgentThreadID) async -> AsyncStream<AgentEvent>
    func availability() async -> AsyncStream<AgentAvailability>
    func archiveThread(_ threadID: AgentThreadID) async throws
    func unarchiveThread(_ threadID: AgentThreadID) async throws
    func deleteThread(_ threadID: AgentThreadID) async throws
    func shutdown() async
}
