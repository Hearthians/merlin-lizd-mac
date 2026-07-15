import Foundation

public enum CodexLaunchConfigurationError: Error, Equatable, Sendable {
    case invalidInitializeResult
}

/// The complete process and protocol boundary for the supported app-server.
/// Authentication and model selection deliberately remain in the inherited
/// local Codex environment/configuration.
public struct CodexLaunchConfiguration: Sendable {
    public static let disabledCapabilities = [
        "shell_tool",
        "unified_exec",
        "apply_patch_freeform",
        "web_search",
        "apps",
        "image_generation",
        "browser_use",
        "computer_use",
        "multi_agent",
        "js_repl",
        "code_mode",
        "tool_search",
        "connectors",
        "plugins",
    ]

    public let executable: URL
    public let runtimeDirectory: URL
    public let environment: [String: String]
    public let arguments: [String]

    public init(
        executable: URL,
        runtimeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.runtimeDirectory = runtimeDirectory
        self.environment = environment
        var arguments = ["app-server", "-c", "mcp_servers={}"]
        for capability in Self.disabledCapabilities {
            arguments.append(contentsOf: [
                "-c", "features.\(capability)=false",
            ])
        }
        self.arguments = arguments
    }

    public var initializeParams: JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("Merlin Lizd"),
                "title": .string("Merlin Lizd"),
                "version": .string("1"),
            ]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])
    }

    public func validateInitializeResult(_ result: JSONValue) throws {
        guard case let .object(fields) = result,
            fields["codexHome"]?.nonemptyString != nil,
            fields["platformFamily"]?.nonemptyString != nil,
            fields["platformOs"]?.nonemptyString != nil,
            fields["userAgent"]?.nonemptyString != nil
        else {
            throw CodexLaunchConfigurationError.invalidInitializeResult
        }
    }

    public var threadStartParams: JSONValue {
        .object([
            "approvalPolicy": .string("never"),
            "cwd": .string(runtimeDirectory.standardizedFileURL.path),
            "sandbox": .string("read-only"),
            "environments": .array([]),
            "runtimeWorkspaceRoots": .array([]),
            "selectedCapabilityRoots": .array([]),
            "ephemeral": .bool(false),
            "dynamicTools": .array([.object([
                "type": .string("namespace"),
                "name": .string(CodexDynamicToolCatalog.namespace),
                "tools": .array([]),
            ])]),
        ])
    }

    public func makeProcess() -> AppServerProcess {
        AppServerProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: runtimeDirectory
        )
    }
}

extension JSONValue {
    var nonemptyString: String? {
        guard case let .string(value) = self, !value.isEmpty else { return nil }
        return value
    }
}
