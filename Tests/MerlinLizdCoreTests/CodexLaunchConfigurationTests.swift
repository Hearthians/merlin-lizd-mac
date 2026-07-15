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
        #expect(configuration.arguments.contains(#"web_search="disabled""#))
        for feature in CodexLaunchConfiguration.disabledFeatureFlags {
            #expect(configuration.arguments.contains("features.\(feature)=false"))
        }
        #expect(configuration.arguments.contains("features.web_search=false") == false)
        #expect(configuration.arguments.contains("features.connectors=false") == false)
        #expect(configuration.arguments.joined(separator: " ").contains("api-key") == false)
        #expect(configuration.arguments.joined(separator: " ").contains("OPENAI_API_KEY") == false)
        #expect(configuration.arguments.joined(separator: " ").contains("model=") == false)
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
        guard case let .object(fields) = params else { return }
        #expect(fields["approvalPolicy"] == .string("never"))
        #expect(fields["cwd"] == .string("/runtime"))
        #expect(fields["sandbox"] == .string("read-only"))
        #expect(fields["environments"] == .array([]))
        #expect(fields["runtimeWorkspaceRoots"] == .array([]))
        #expect(fields["selectedCapabilityRoots"] == .array([]))
        #expect(fields["ephemeral"] == .bool(false))
        #expect(fields["model"] == nil)
        guard case let .array(dynamicTools)? = fields["dynamicTools"],
            dynamicTools.count == 1,
            case let .object(namespace) = dynamicTools[0],
            case let .array(tools)? = namespace["tools"]
        else {
            Issue.record("missing merlin_tmux namespace")
            return
        }
        #expect(namespace["type"] == .string("namespace"))
        #expect(namespace["name"] == .string("merlin_tmux"))
        #expect(namespace["description"]?.nonemptyString != nil)
        #expect(tools.count == 6)
        #expect(tools.compactMap { value -> String? in
            guard case let .object(tool) = value,
                tool["type"] == .string("function"),
                tool["description"]?.nonemptyString != nil,
                tool["inputSchema"] != nil
            else { return nil }
            return tool["name"]?.nonemptyString
        } == CodexDynamicToolCatalog.tools.map(\.name))
    }
}
