import Foundation
import MerlinLizdCore

public enum CodexDynamicToolError: Error, Equatable, Sendable {
    case unknownNamespace
    case unknownTool
    case invalidArguments
}

public struct CodexDynamicToolDefinition: Equatable, Sendable {
    public let namespace: String
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(
        namespace: String,
        name: String,
        description: String,
        inputSchema: JSONValue
    ) {
        self.namespace = namespace
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public protocol CodexDynamicToolExecuting: Sendable {
    func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult
}

public enum CodexTerminalToolExecutorError: Error, Equatable, Sendable {
    case mismatchedThread
    case bindingExists
    case bindingUnavailable
}

/// Bridges the adapter boundary to Core without teaching Core about Dynamic
/// Tools. A prepared binding can be installed before `turn/start`; therefore a
/// server tool request racing that continuation still activates the exact
/// prepared router generation.
public actor CodexTerminalToolExecutor: CodexDynamicToolExecuting {
    private struct Binding: Sendable {
        let handle: AgentTurnHandle
        let conversationKey: TerminalConversationKey
    }

    private let router: TerminalToolRouter
    private var bindings: [AgentThreadID: Binding] = [:]

    public init(router: TerminalToolRouter) {
        self.router = router
    }

    public func bindPreparedTurn(
        threadID: AgentThreadID,
        handle: AgentTurnHandle,
        conversationKey: TerminalConversationKey
    ) throws {
        guard handle.threadID == threadID else {
            throw CodexTerminalToolExecutorError.mismatchedThread
        }
        if let existing = bindings[threadID] {
            guard existing.handle == handle,
                existing.conversationKey == conversationKey
            else {
                throw CodexTerminalToolExecutorError.bindingExists
            }
            return
        }
        bindings[threadID] = Binding(
            handle: handle,
            conversationKey: conversationKey
        )
    }

    public func unbind(threadID: AgentThreadID, handle: AgentTurnHandle) {
        guard bindings[threadID]?.handle == handle else { return }
        bindings.removeValue(forKey: threadID)
    }

    public func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        guard let binding = bindings[threadID] else {
            throw CodexTerminalToolExecutorError.bindingUnavailable
        }
        return try await router.execute(
            handle: binding.handle,
            turnID: turnID,
            conversationKey: binding.conversationKey,
            call: call
        )
    }
}

public enum CodexDynamicToolCatalog {
    public static let namespace = "merlin_tmux"
    public static let namespaceDescription = "Guarded operations for the "
        + "current visible tmux pane. Observe before acting; hidden panes are "
        + "never read, mutations require an exact screen revision, and user "
        + "approval may pause execution."
    private static let maximumArgumentsBytes = 32 * 1_024
    private static let maximumEvents = 256
    private static let maximumPurposeScalars = 500
    private static let maximumWaitMilliseconds = 120_000
    private static let maximumSafeJSONInteger = 9_007_199_254_740_991
    private static let sharedDescription = "Operate the current visible pane "
        + "only. Observe the rendered screen before acting; every mutation "
        + "requires the exact expected revision. Use wait_for_screen instead "
        + "of a fixed sleep. Never read a hidden pane. A high-risk action may "
        + "pause for user approval."

    public static let tools: [CodexDynamicToolDefinition] = [
        definition("observe_screen", properties: [:], required: []),
        definition(
            "send_input",
            properties: [
                "expectedRevision": unsignedIntegerSchema,
                "events": .object([
                    "type": .string("array"),
                    "minItems": .number(1),
                    "maxItems": .number(Double(maximumEvents)),
                    "items": inputEventSchema,
                ]),
                "purpose": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(Double(maximumPurposeScalars)),
                ]),
                "declaredRisk": enumSchema(["observation", "routine", "high"]),
            ],
            required: [
                "expectedRevision", "events", "purpose", "declaredRisk",
            ]
        ),
        definition(
            "wait_for_screen",
            properties: [
                "condition": enumSchema(["changed", "stable"]),
                "afterRevision": unsignedIntegerSchema,
                "stableMilliseconds": boundedIntegerSchema(
                    minimum: 0,
                    maximum: maximumWaitMilliseconds
                ),
                "timeoutMilliseconds": boundedIntegerSchema(
                    minimum: 0,
                    maximum: maximumWaitMilliseconds
                ),
            ],
            required: ["condition", "afterRevision", "timeoutMilliseconds"]
        ),
        definition(
            "select_visible_surface",
            properties: [
                "selection": enumSchema([
                    "next_window", "previous_window", "window_index",
                    "pane_left", "pane_right", "pane_up", "pane_down",
                    "next_pane", "previous_pane",
                ]),
                "windowIndex": boundedIntegerSchema(
                    minimum: 0,
                    maximum: Int.max
                ),
                "expectedRevision": unsignedIntegerSchema,
            ],
            required: ["selection", "expectedRevision"]
        ),
        definition(
            "create_temporary_pane",
            properties: ["expectedRevision": unsignedIntegerSchema],
            required: ["expectedRevision"]
        ),
        definition(
            "finish_temporary_pane",
            properties: [
                "leaseId": .object([
                    "type": .string("string"),
                    "format": .string("uuid"),
                ]),
                "expectedRevision": unsignedIntegerSchema,
            ],
            required: ["leaseId", "expectedRevision"]
        ),
    ]

    public static func decode(
        namespace: String?,
        tool: String,
        arguments: JSONValue
    ) throws -> TerminalToolCall {
        guard namespace == Self.namespace else {
            throw CodexDynamicToolError.unknownNamespace
        }
        guard tools.contains(where: { $0.name == tool }) else {
            throw CodexDynamicToolError.unknownTool
        }
        guard encodedByteCount(arguments) <= maximumArgumentsBytes,
            case let .object(fields) = arguments
        else {
            throw CodexDynamicToolError.invalidArguments
        }

        switch tool {
        case "observe_screen":
            try requireExactKeys(fields, allowed: [])
            return .observeScreen
        case "send_input":
            try requireExactKeys(
                fields,
                allowed: [
                    "expectedRevision", "events", "purpose", "declaredRisk",
                ]
            )
            guard let revision = unsigned(fields["expectedRevision"]),
                case let .array(eventValues)? = fields["events"],
                (1...maximumEvents).contains(eventValues.count),
                let purpose = fields["purpose"]?.nonemptyString,
                purpose.unicodeScalars.count <= maximumPurposeScalars,
                let risk = risk(fields["declaredRisk"])
            else { throw CodexDynamicToolError.invalidArguments }
            let events = try eventValues.map(decodeEvent)
            return .sendInput(.init(
                expectedRevision: revision,
                events: events,
                purpose: purpose,
                declaredRisk: risk
            ))
        case "wait_for_screen":
            try requireKeys(
                fields,
                required: [
                    "condition", "afterRevision", "timeoutMilliseconds",
                ],
                allowed: [
                    "condition", "afterRevision", "stableMilliseconds",
                    "timeoutMilliseconds",
                ]
            )
            guard let condition = fields["condition"]?.nonemptyString,
                let revision = unsigned(fields["afterRevision"]),
                let timeout = boundedInt(
                    fields["timeoutMilliseconds"],
                    maximum: maximumWaitMilliseconds
                )
            else { throw CodexDynamicToolError.invalidArguments }
            let waitCondition: TerminalScreenWaitCondition
            switch condition {
            case "changed":
                guard fields["stableMilliseconds"] == nil else {
                    throw CodexDynamicToolError.invalidArguments
                }
                waitCondition = .changed(after: revision)
            case "stable":
                guard let stable = boundedInt(
                    fields["stableMilliseconds"],
                    maximum: maximumWaitMilliseconds
                ) else { throw CodexDynamicToolError.invalidArguments }
                waitCondition = .stable(
                    after: revision,
                    for: .milliseconds(stable)
                )
            default:
                throw CodexDynamicToolError.invalidArguments
            }
            return .waitForScreen(.init(
                condition: waitCondition,
                timeout: .milliseconds(timeout)
            ))
        case "select_visible_surface":
            try requireKeys(
                fields,
                required: ["selection", "expectedRevision"],
                allowed: ["selection", "windowIndex", "expectedRevision"]
            )
            guard let name = fields["selection"]?.nonemptyString,
                let revision = unsigned(fields["expectedRevision"])
            else { throw CodexDynamicToolError.invalidArguments }
            return .selectVisibleSurface(
                try selection(name, index: fields["windowIndex"]),
                expectedRevision: revision
            )
        case "create_temporary_pane":
            try requireExactKeys(fields, allowed: ["expectedRevision"])
            guard let revision = unsigned(fields["expectedRevision"])
            else { throw CodexDynamicToolError.invalidArguments }
            return .createTemporaryPane(expectedRevision: revision)
        case "finish_temporary_pane":
            try requireExactKeys(
                fields,
                allowed: ["leaseId", "expectedRevision"]
            )
            guard let leaseText = fields["leaseId"]?.nonemptyString,
                let leaseID = UUID(uuidString: leaseText),
                let revision = unsigned(fields["expectedRevision"])
            else { throw CodexDynamicToolError.invalidArguments }
            return .finishTemporaryPane(
                leaseID: leaseID,
                expectedRevision: revision
            )
        default:
            throw CodexDynamicToolError.unknownTool
        }
    }

    public static func response(
        for result: TerminalToolResult
    ) throws -> JSONValue {
        let data = try JSONEncoder().encode(result)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return toolResponse(text: try compactJSON(value), success: true)
    }

    public static func failureResponse(for error: any Error) -> JSONValue {
        let message: String
        switch error {
        case TerminalToolRouterError.approvalDenied:
            message = "The user denied this terminal operation."
        case TerminalToolRouterError.approvalExpired,
            TerminalToolRouterError.staleRevision:
            message = "The visible terminal changed; observe it again before retrying."
        case TerminalToolRouterError.interrupted:
            message = "The terminal operation was interrupted."
        case TerminalToolRouterError.auditUnavailable:
            message = "The terminal audit journal is unavailable; the operation was not executed."
        default:
            message = "The terminal operation could not be completed safely."
        }
        return toolResponse(text: message, success: false)
    }

    private static func toolResponse(text: String, success: Bool) -> JSONValue {
        .object([
            "contentItems": .array([.object([
                "type": .string("inputText"),
                "text": .string(text),
            ])]),
            "success": .bool(success),
        ])
    }

    private static func definition(
        _ name: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> CodexDynamicToolDefinition {
        CodexDynamicToolDefinition(
            namespace: namespace,
            name: name,
            description: sharedDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static var unsignedIntegerSchema: JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(0),
            "maximum": .number(Double(maximumSafeJSONInteger)),
        ])
    }

    private static func boundedIntegerSchema(
        minimum: Int,
        maximum: Int
    ) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(Double(minimum)),
            "maximum": .number(Double(min(maximum, maximumSafeJSONInteger))),
        ])
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    private static var inputEventSchema: JSONValue {
        .object([
            "oneOf": .array([
                .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("text")]),
                        "text": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("type"), .string("text")]),
                    "additionalProperties": .bool(false),
                ]),
                .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("key")]),
                        "key": enumSchema(keyNames),
                        "character": .object(["type": .string("string")]),
                        "function": boundedIntegerSchema(minimum: 1, maximum: 12),
                        "modifiers": .object([
                            "type": .string("array"),
                            "uniqueItems": .bool(true),
                            "items": enumSchema([
                                "shift", "control", "option", "command",
                            ]),
                        ]),
                    ]),
                    "required": .array([
                        .string("type"), .string("key"), .string("modifiers"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ])
    }

    private static let keyNames = [
        "character", "enter", "escape", "backspace", "tab", "up", "down",
        "right", "left", "home", "end", "insert", "delete", "page_up",
        "page_down", "function",
    ]

    private static func requireExactKeys(
        _ fields: [String: JSONValue],
        allowed: Set<String>
    ) throws {
        try requireKeys(fields, required: allowed, allowed: allowed)
    }

    private static func requireKeys(
        _ fields: [String: JSONValue],
        required: Set<String>,
        allowed: Set<String>
    ) throws {
        let keys = Set(fields.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
            throw CodexDynamicToolError.invalidArguments
        }
    }

    private static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard case let .number(number)? = value,
            number >= 0,
            number.rounded(.towardZero) == number,
            number <= Double(maximumSafeJSONInteger)
        else { return nil }
        return UInt64(number)
    }

    private static func boundedInt(
        _ value: JSONValue?,
        maximum: Int
    ) -> Int? {
        guard case let .number(number)? = value,
            number >= 0,
            number <= Double(min(maximum, maximumSafeJSONInteger)),
            number.rounded(.towardZero) == number
        else { return nil }
        return Int(number)
    }

    private static func risk(_ value: JSONValue?) -> TerminalRisk? {
        switch value?.nonemptyString {
        case "observation": .observation
        case "routine": .routine
        case "high": .high
        default: nil
        }
    }

    private static func decodeEvent(
        _ value: JSONValue
    ) throws -> TerminalInputEvent {
        guard case let .object(fields) = value,
            let type = fields["type"]?.nonemptyString
        else { throw CodexDynamicToolError.invalidArguments }
        switch type {
        case "text":
            try requireExactKeys(fields, allowed: ["type", "text"])
            guard case let .string(text)? = fields["text"], !text.isEmpty
            else { throw CodexDynamicToolError.invalidArguments }
            return .text(text)
        case "key":
            let allowed: Set<String> = [
                "type", "key", "character", "function", "modifiers",
            ]
            guard Set(fields.keys).isSubset(of: allowed),
                fields["type"] != nil,
                fields["key"] != nil,
                fields["modifiers"] != nil,
                let name = fields["key"]?.nonemptyString,
                case let .array(modifierValues)? = fields["modifiers"]
            else { throw CodexDynamicToolError.invalidArguments }
            let modifiers = try decodeModifiers(modifierValues)
            return .key(
                try decodeKey(
                    name,
                    character: fields["character"],
                    function: fields["function"]
                ),
                modifiers: modifiers
            )
        default:
            throw CodexDynamicToolError.invalidArguments
        }
    }

    private static func decodeModifiers(
        _ values: [JSONValue]
    ) throws -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        for value in values {
            let modifier: TerminalKeyModifiers
            switch value.nonemptyString {
            case "shift": modifier = .shift
            case "control": modifier = .control
            case "option": modifier = .option
            case "command": modifier = .command
            default: throw CodexDynamicToolError.invalidArguments
            }
            guard !result.contains(modifier) else {
                throw CodexDynamicToolError.invalidArguments
            }
            result.insert(modifier)
        }
        return result
    }

    private static func decodeKey(
        _ name: String,
        character: JSONValue?,
        function: JSONValue?
    ) throws -> TerminalKey {
        if name == "character" {
            guard function == nil, case let .string(value)? = character,
                value.count == 1
            else { throw CodexDynamicToolError.invalidArguments }
            return .character(value)
        }
        if name == "function" {
            guard character == nil,
                let number = boundedInt(function, maximum: 12), number >= 1
            else { throw CodexDynamicToolError.invalidArguments }
            return .function(number)
        }
        guard character == nil, function == nil else {
            throw CodexDynamicToolError.invalidArguments
        }
        switch name {
        case "enter": return .enter
        case "escape": return .escape
        case "backspace": return .backspace
        case "tab": return .tab
        case "up": return .up
        case "down": return .down
        case "right": return .right
        case "left": return .left
        case "home": return .home
        case "end": return .end
        case "insert": return .insert
        case "delete": return .delete
        case "page_up": return .pageUp
        case "page_down": return .pageDown
        default: throw CodexDynamicToolError.invalidArguments
        }
    }

    private static func selection(
        _ name: String,
        index: JSONValue?
    ) throws -> TmuxVisibleSelection {
        switch name {
        case "next_window" where index == nil: return .nextWindow
        case "previous_window" where index == nil: return .previousWindow
        case "window_index":
            guard let index = boundedInt(index, maximum: Int.max) else {
                throw CodexDynamicToolError.invalidArguments
            }
            return .windowIndex(index)
        case "pane_left" where index == nil: return .paneLeft
        case "pane_right" where index == nil: return .paneRight
        case "pane_up" where index == nil: return .paneUp
        case "pane_down" where index == nil: return .paneDown
        case "next_pane" where index == nil: return .nextPane
        case "previous_pane" where index == nil: return .previousPane
        default: throw CodexDynamicToolError.invalidArguments
        }
    }

    private static func encodedByteCount(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
    }

    private static func compactJSON(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
