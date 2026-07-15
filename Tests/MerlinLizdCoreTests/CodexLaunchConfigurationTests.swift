import Testing
@testable import MerlinLizdCodexAdapter

@Suite("Codex launch configuration")
struct CodexLaunchConfigurationTests {
    @Test("app-server launch inherits auth environment and disables every non-terminal capability")
    func isolatesCapabilitiesWithoutInjectingCredentials() {
        let environment = [
            "CODEX_HOME": "/Users/test/.codex",
            "OPENAI_API_KEY": "inherited-but-never-an-argument",
            "CODEX_SESSION": "existing-login",
        ]
        let configuration = CodexLaunchConfiguration(
            executable: testURL("/usr/local/bin/codex"),
            runtimeDirectory: testURL("/runtime"),
            environment: environment
        )

        #expect(configuration.arguments.first == "app-server")
        #expect(configuration.environment == environment)
        #expect(configuration.arguments.contains("mcp_servers={}"))
        for capability in CodexLaunchConfiguration.disabledCapabilities {
            #expect(configuration.arguments.contains("features.\(capability)=false"))
        }
        #expect(configuration.arguments.joined(separator: " ").contains("api-key") == false)
        #expect(configuration.arguments.joined(separator: " ").contains("OPENAI_API_KEY") == false)
    }

    @Test("initialize enables the experimental API and validates platform metadata")
    func initializesAndValidatesMetadata() throws {
        let configuration = CodexLaunchConfiguration(
            executable: testURL("/codex"),
            runtimeDirectory: testURL("/runtime"),
            environment: [:]
        )
        let expected: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("Merlin Lizd"),
                "title": .string("Merlin Lizd"),
                "version": .string("1"),
            ]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])
        #expect(configuration.initializeParams == expected)
        try configuration.validateInitializeResult(JSONValue.object([
            "codexHome": .string("/Users/test/.codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex-cli/0.144.2"),
        ]))
        #expect(throws: CodexLaunchConfigurationError.invalidInitializeResult) {
            try configuration.validateInitializeResult(JSONValue.object([
                "codexHome": .string("/Users/test/.codex"),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
            ]))
        }
    }

    @Test("thread start is read-only and leaves local model selection untouched")
    func exactThreadStartBoundary() {
        let configuration = CodexLaunchConfiguration(
            executable: testURL("/codex"),
            runtimeDirectory: testURL("/runtime"),
            environment: [:]
        )
        let params = configuration.threadStartParams
        let expected: JSONValue = .object([
            "approvalPolicy": .string("never"),
            "cwd": .string("/runtime"),
            "sandbox": .string("read-only"),
            "environments": .array([]),
            "runtimeWorkspaceRoots": .array([]),
            "selectedCapabilityRoots": .array([]),
            "ephemeral": .bool(false),
            "dynamicTools": .array([.object([
                "type": .string("namespace"),
                "name": .string("merlin_tmux"),
                "tools": .array([]),
            ])]),
        ])
        #expect(params == expected)
        guard case let .object(fields) = params else { return }
        #expect(fields["model"] == nil)
    }
}
