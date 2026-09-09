import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Herdr discovery and stable terminal binding")
struct HerdrTests {
    private static let sessions = #"{"sessions":[{"default":true,"name":"default","running":true},{"default":false,"name":"research.lab","running":true},{"default":false,"name":"stopped","running":false}]}"#

    private func snapshot(
        terminalID: String = "term_123", paneID: String = "w1:p1", workspaceID: String = "w1",
        cwd: String? = "/home/user/project", foregroundCwd: String? = "/home/user/project/subdirectory",
        agentSession: [String: String]? = nil
    ) throws -> String {
        var pane: [String: Any] = [
            "terminal_id": terminalID, "pane_id": paneID, "workspace_id": workspaceID,
            "agent": "codex", "agent_status": "unknown",
            "terminal_title_stripped": "Research", "unrecognized_future_field": "ignored",
        ]
        if let cwd { pane["cwd"] = cwd }
        if let foregroundCwd { pane["foreground_cwd"] = foregroundCwd }
        if let agentSession { pane["agent_session"] = agentSession }
        let object: [String: Any] = [
            "result": ["snapshot": [
                "focused_pane_id": "w9:p9",
                "workspaces": [["workspace_id": workspaceID, "label": "Research"]],
                "panes": [pane],
            ]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("parses only running default and named sessions without inventing a default")
    func sessionDiscovery() throws {
        let sessions = try HerdrParser.sessions(Self.sessions)
        #expect(sessions.count == 2)
        #expect(sessions[0].name == "default")
        #expect(sessions[0].sessionName == nil)
        #expect(sessions[1].sessionName == "research.lab")
        #expect(try HerdrParser.sessions(#"{"sessions":[]}"#).isEmpty)
    }

    @Test("binds foreground cwd and terminal identity, not the globally focused pane")
    func boundContext() throws {
        let parsed = try HerdrParser.snapshot(snapshot(), sessionName: nil)
        let reference = HerdrTerminalReference(terminalID: "term_123")
        let pane = try HerdrParser.resolve(reference, in: parsed)
        #expect(pane.paneID == "w1:p1")
        #expect(pane.workingDirectory == "/home/user/project/subdirectory")
        #expect(pane.agentStatus == "unknown")
        #expect(parsed.workspaces[0].cwd == "/home/user/project")
        #expect(pane.label == "Research")
        let fallback = try HerdrParser.snapshot(snapshot(foregroundCwd: nil), sessionName: nil)
        #expect(try HerdrParser.resolve(reference, in: fallback).workingDirectory == "/home/user/project")
    }

    @Test("panes without directory metadata remain discoverable without inventing a path")
    func missingDirectories() throws {
        let reference = HerdrTerminalReference(terminalID: "term_123")
        let missing = try HerdrParser.snapshot(snapshot(cwd: nil, foregroundCwd: nil), sessionName: nil)
        #expect(missing.workspaces[0].cwd == nil)
        #expect(try HerdrParser.resolve(reference, in: missing).workingDirectory == nil)
        let foreground = try HerdrParser.snapshot(snapshot(cwd: nil), sessionName: nil)
        #expect(try HerdrParser.resolve(reference, in: foreground).workingDirectory == "/home/user/project/subdirectory")
        let explicitNull = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term_123","workspace_id":"w1","cwd":null,"foreground_cwd":null}]}}}"#
        #expect(try HerdrParser.resolve(reference, in: HerdrParser.snapshot(explicitNull, sessionName: nil)).workingDirectory == nil)
    }

    @Test("tracks the same terminal after a pane move and rejects a reused pane")
    func movesAndReplacement() throws {
        let reference = HerdrTerminalReference(terminalID: "term_123")
        let moved = try HerdrParser.snapshot(
            snapshot(paneID: "w2:p9", workspaceID: "w2"), sessionName: nil
        )
        #expect(try HerdrParser.resolve(reference, in: moved).paneID == "w2:p9")
        let replaced = try HerdrParser.snapshot(snapshot(terminalID: "term_456"), sessionName: nil)
        #expect(throws: HerdrError.terminalUnavailable) {
            try HerdrParser.resolve(reference, in: replaced)
        }
        let named = try HerdrParser.snapshot(snapshot(), sessionName: "research.lab")
        #expect(throws: HerdrError.terminalUnavailable) {
            try HerdrParser.resolve(reference, in: named)
        }
        #expect(try HerdrParser.resolve(
            .init(sessionName: "research.lab", terminalID: "term_123"), in: named
        ).reference.sessionName == "research.lab")
    }

    @Test("refuses incomplete snapshots, ambiguous identity and invalid paths")
    func malformedSnapshots() throws {
        for json in ["not json", "{}", #"{"result":{"snapshot":{"panes":[]}}}"#,
            #"{"result":{"snapshot":{"workspaces":[],"panes":[{}]}}}"#] {
            #expect(throws: HerdrError.self) { try HerdrParser.snapshot(json, sessionName: nil) }
        }
        let base = try JSONSerialization.jsonObject(with: Data(snapshot().utf8)) as! [String: Any]
        let original = (base["result"] as! [String: Any])["snapshot"] as! [String: Any]
        for key in ["panes", "workspaces"] {
            var duplicate = original
            let records = original[key] as! [[String: Any]]
            duplicate[key] = records + records
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [
                "result": ["snapshot": duplicate]
            ]), as: UTF8.self)
            #expect(throws: HerdrError.malformedResponse) {
                try HerdrParser.snapshot(json, sessionName: nil)
            }
        }
        for path in ["relative", "/tmp/a\ncommand", "/tmp/a\u{1b}", "/tmp/a\tvalue"] {
            let json = try snapshot(cwd: path)
            #expect(throws: HerdrError.invalidPath) { try HerdrParser.snapshot(json, sessionName: nil) }
        }
        let foreground = try snapshot(foregroundCwd: "relative")
        #expect(throws: HerdrError.invalidPath) {
            try HerdrParser.snapshot(foreground, sessionName: nil)
        }
    }

    @Test("preserves literal quotes and Unicode in valid cwd values")
    func literalPaths() throws {
        let path = "/home/user/研究 ' $(false); project"
        let parsed = try HerdrParser.snapshot(snapshot(cwd: path, foregroundCwd: nil), sessionName: nil)
        #expect(parsed.workspaces[0].panes[0].workingDirectory == path)
    }

    @Test("validates restored references before querying or constructing commands")
    func invalidReferences() throws {
        for id in ["", "--takeover", "term_a;echo", "term_a\n", "term_'x", "$(false)"] {
            let reference = HerdrTerminalReference(terminalID: id)
            #expect(!reference.isValid)
            #expect(throws: HerdrError.invalidIdentifier) {
                try HerdrCommands.attach(target: .ssh(destination: "cis-lab"), reference: reference)
            }
        }
        for name in ["--session", "research'lab", "$(false)", "one\ntwo"] {
            #expect(!HerdrTerminalReference(sessionName: name, terminalID: "term_123").isValid)
        }
        #expect(HerdrTerminalReference(sessionName: "research.lab", terminalID: "term_123").isValid)
    }

    @Test("remote attach uses official terminal attach without takeover or lifecycle changes")
    func attachCommand() throws {
        let command = try HerdrCommands.attach(
            target: .ssh(destination: "cis-lab"),
            reference: .init(sessionName: "research.lab", terminalID: "term_123")
        )
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.first == "-tt")
        #expect(command.arguments[command.arguments.count - 2] == "cis-lab")
        let remote = command.arguments.last!
        #expect(remote.hasPrefix("exec /bin/sh -c '"))
        #expect(remote.contains("HERDR_SESSION HERDR_SOCKET_PATH"))
        #expect(remote.contains("terminal"))
        #expect(remote.contains("attach"))
        #expect(remote.contains("term_123"))
        #expect(remote.contains("research.lab"))
        for prohibited in ["--takeover", "new-session", "tmux", "server stop", "update", "install.sh"] {
            #expect(!remote.contains(prohibited))
        }
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try HerdrCommands.attach(
                target: .ssh(destination: "-oProxyCommand=bad"), reference: .init(terminalID: "term_123")
            )
        }
    }

    @Test("shell quoting round trips metacharacters as inert data")
    func shellQuoting() async throws {
        let value = "path with ' single \" double $(false); `false` \\ 中文"
        let command = CommandSpec(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' " + HerdrCommands.shellQuote(value)]
        )
        let output = try await FoundationInventoryProcessRunner().run(command)
        #expect(output.exitCode == 0)
        #expect(output.stdout == value)
    }

    @Test("service lists sessions then reads each session explicitly")
    func serviceDiscovery() async throws {
        let runner = HerdrFixtureRunner(outputs: [
            .init(stdout: Self.sessions, stderr: "", exitCode: 0),
            .init(stdout: try snapshot(), stderr: "", exitCode: 0),
            .init(stdout: try snapshot(terminalID: "term_named"), stderr: "", exitCode: 0),
        ])
        let service = HerdrService(processRunner: runner)
        let sessions = try await service.discover(target: .ssh(destination: "cis-lab"))
        #expect(sessions.count == 2)
        #expect(sessions[0].sessionName == nil)
        #expect(sessions[1].workspaces[0].panes[0].reference.sessionName == "research.lab")
        let commands = await runner.commands()
        #expect(commands.count == 3)
        #expect(commands.allSatisfy { $0.arguments.contains("-nT") })
        #expect(commands.last!.arguments.last!.contains("research.lab"))
        #expect(!commands[1].arguments.last!.contains("research.lab"))
    }

    @Test("service resolve refreshes the bound terminal and does not fall back to another pane")
    func serviceResolve() async throws {
        let runner = HerdrFixtureRunner(outputs: [
            .init(stdout: try snapshot(terminalID: "term_replacement"), stderr: "", exitCode: 0)
        ])
        let service = HerdrService(processRunner: runner)
        await #expect(throws: HerdrError.terminalUnavailable) {
            try await service.resolve(
                target: .ssh(destination: "cis-lab"), reference: .init(terminalID: "term_original")
            )
        }
        #expect(await runner.commands().count == 1)
    }

    @Test("missing binary and stopped servers remain visible errors")
    func availabilityErrors() async throws {
        for (output, expected) in [
            (InventoryProcessOutput(stdout: "", stderr: "", exitCode: 127), HerdrError.notInstalled),
            (.init(stdout: #"{"sessions":[]}"#, stderr: "", exitCode: 0), .noRunningSessions),
            (.init(stdout: "", stderr: #"{"error":{"code":"server_unavailable"}}"#, exitCode: 1), .serverUnavailable),
        ] {
            let runner = HerdrFixtureRunner(outputs: [output])
            let service = HerdrService(processRunner: runner)
            await #expect(throws: expected) {
                try await service.discover(target: .ssh(destination: "cis-lab"))
            }
            #expect(await runner.commands().count == 1)
        }
        #expect(throws: HerdrError.unsupportedOperation) {
            try HerdrParser.snapshot(#"{"error":{"code":"method_not_found"}}"#, sessionName: nil)
        }
    }

    @Test("legacy tab state remains readable and Herdr references round trip")
    func persistenceCompatibility() throws {
        let legacy = #"{"selectedTabID":"old-tab","tabs":[{"id":"old-tab","title":"Existing terminal","target":{"ssh":{"destination":"cis-lab"}},"sessionName":"existing-session"}]}"#
        let decoded = try TerminalStateCodec.decode(legacy)
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].herdrReference == nil)
        #expect(decoded.tabs[0].sessionName == "existing-session")
        #expect(decoded.tabs[0].target == .ssh(destination: "cis-lab"))

        let state = TerminalState(selectedTabID: "named", tabs: [
            .init(id: "default", title: "Research", target: .ssh(destination: "cis-lab"),
                  sessionName: nil, herdrReference: .init(terminalID: "term_default")),
            .init(id: "named", title: "Review", target: .ssh(destination: "cis-lab"),
                  sessionName: nil, herdrReference: .init(sessionName: "research.lab", terminalID: "term_named")),
        ])
        let restored = try TerminalStateCodec.decode(TerminalStateCodec.encode(state))
        #expect(restored == state)
        #expect(restored.tabs[0].herdrReference?.sessionName == nil)
        #expect(restored.tabs[1].herdrReference?.sessionName == "research.lab")
        #expect(restored.tabs.allSatisfy { $0.herdrReference?.isValid == true })
    }

    @Test("attachment context uses the selected Herdr terminal and its foreground directory")
    func attachmentContext() async throws {
        let fixture = try snapshot(paneID: "w2:p9", workspaceID: "w2")
        let runner = HerdrFixtureRunner(outputs: [.init(stdout: fixture, stderr: "", exitCode: 0)])
        let service = AttachmentTransferService(
            sshMasterPool: SSHMasterPool(), herdrService: HerdrService(processRunner: runner)
        )
        let reference = HerdrTerminalReference(sessionName: "research.lab", terminalID: "term_123")
        let context = try await service.context(
            target: .ssh(destination: "cis-lab"), sessionName: nil,
            localDirectory: "/must-not-be-used", herdrReference: reference
        )
        #expect(context.workingDirectory == "/home/user/project/subdirectory")
        #expect(context.herdrReference == reference)
        #expect(context.paneID == "w2:p9")
        #expect(context.sessionName == nil)
        #expect(context.processName == "codex")
        let commands = await runner.commands()
        #expect(commands.count == 1)
        #expect(!commands[0].arguments.last!.contains("tmux"))
        #expect(commands[0].arguments.last!.contains("research.lab"))
    }

    @Test("stale Herdr attachment targets fail without falling back to another context")
    func attachmentStaleTarget() async throws {
        let fixture = try snapshot(terminalID: "term_replacement")
        let runner = HerdrFixtureRunner(outputs: [.init(stdout: fixture, stderr: "", exitCode: 0)])
        let service = AttachmentTransferService(
            sshMasterPool: SSHMasterPool(), herdrService: HerdrService(processRunner: runner)
        )
        await #expect(throws: HerdrError.terminalUnavailable) {
            try await service.context(
                target: .ssh(destination: "cis-lab"), sessionName: nil,
                localDirectory: "/must-not-be-used", herdrReference: .init(terminalID: "term_original")
            )
        }
        #expect(await runner.commands().count == 1)
        await #expect(throws: AttachmentError.contextUnavailable) {
            try await service.context(
                target: .ssh(destination: "cis-lab"), sessionName: "ambiguous-tmux-session",
                localDirectory: "/must-not-be-used", herdrReference: .init(terminalID: "term_original")
            )
        }
        #expect(await runner.commands().count == 1)
    }

    @Test("occupant identity changes when an agent session is replaced in the same terminal")
    func agentOccupantIdentity() throws {
        let session = ["source": "herdr:codex", "agent": "codex", "kind": "id", "value": "agent-session-1"]
        let reference = HerdrTerminalReference(terminalID: "term_123")
        let original = try HerdrParser.resolve(reference, in: HerdrParser.snapshot(
            snapshot(agentSession: session), sessionName: nil
        ))
        #expect(original.occupantID != nil)
        let same = try HerdrParser.resolve(reference, in: HerdrParser.snapshot(
            snapshot(agentSession: session), sessionName: nil
        ))
        #expect(same.occupantID == original.occupantID)
        let moved = try HerdrParser.resolve(reference, in: HerdrParser.snapshot(
            snapshot(paneID: "w2:p9", workspaceID: "w2", agentSession: session), sessionName: nil
        ))
        #expect(moved.occupantID == original.occupantID)

        for field in ["source", "agent", "kind", "value"] {
            var changed = session
            changed[field] = "changed"
            let replacement = try HerdrParser.resolve(reference, in: HerdrParser.snapshot(
                snapshot(agentSession: changed), sessionName: nil
            ))
            #expect(replacement.reference == original.reference)
            #expect(replacement.paneID == original.paneID)
            #expect(replacement.workingDirectory == original.workingDirectory)
            #expect(replacement.occupantID != original.occupantID)
        }
        let unknown = try HerdrParser.resolve(reference, in: HerdrParser.snapshot(snapshot(), sessionName: nil))
        #expect(unknown.occupantID == nil)
        #expect(unknown.occupantID != original.occupantID)
    }

    @Test("malformed agent session identity cannot silently remove the identity guard")
    func malformedAgentOccupant() throws {
        for session in [
            ["source": "herdr:codex", "agent": "codex", "kind": "id", "value": ""],
            ["source": "herdr:codex", "agent": "codex", "kind": "id", "value": "one\ntwo"],
            ["source": "herdr:codex", "agent": "codex", "kind": "id"],
        ] {
            let json = try snapshot(agentSession: session)
            #expect(throws: HerdrError.malformedResponse) {
                try HerdrParser.snapshot(json, sessionName: nil)
            }
        }
        let pathSession = [
            "source": "plugin:agent", "agent": "custom", "kind": "path",
            "value": "/home/user/研究 ' $(false).jsonl",
        ]
        let parsed = try HerdrParser.snapshot(snapshot(agentSession: pathSession), sessionName: nil)
        #expect(parsed.workspaces[0].panes[0].occupantID != nil)
    }

    @Test("attachment revalidation detects a replaced agent session in an unchanged terminal")
    func attachmentOccupantChange() async throws {
        let session = ["source": "herdr:codex", "agent": "codex", "kind": "id", "value": "session-1"]
        var nextSession = session
        nextSession["value"] = "session-2"
        let runner = HerdrFixtureRunner(outputs: [
            .init(stdout: try snapshot(agentSession: session), stderr: "", exitCode: 0),
            .init(stdout: try snapshot(agentSession: nextSession), stderr: "", exitCode: 0),
        ])
        let service = AttachmentTransferService(
            sshMasterPool: SSHMasterPool(), herdrService: HerdrService(processRunner: runner)
        )
        let reference = HerdrTerminalReference(terminalID: "term_123")
        let before = try await service.context(
            target: .ssh(destination: "cis-lab"), sessionName: nil,
            localDirectory: "/unused", herdrReference: reference
        )
        let after = try await service.context(
            target: .ssh(destination: "cis-lab"), sessionName: nil,
            localDirectory: "/unused", herdrReference: reference
        )
        #expect(before.paneID == after.paneID)
        #expect(before.processName == after.processName)
        #expect(before.workingDirectory == after.workingDirectory)
        #expect(before.herdrReference == after.herdrReference)
        #expect(before.herdrOccupantID != nil)
        #expect(before.herdrOccupantID != after.herdrOccupantID)
        #expect(before != after)
    }

    @Test("directory-less terminals can be browsed but cannot receive attachments")
    func attachmentMissingDirectory() async throws {
        let runner = HerdrFixtureRunner(outputs: [
            .init(stdout: try snapshot(cwd: nil, foregroundCwd: nil), stderr: "", exitCode: 0)
        ])
        let service = AttachmentTransferService(
            sshMasterPool: SSHMasterPool(), herdrService: HerdrService(processRunner: runner)
        )
        await #expect(throws: AttachmentError.contextUnavailable) {
            try await service.context(
                target: .ssh(destination: "cis-lab"), sessionName: nil,
                localDirectory: "/must-not-be-used", herdrReference: .init(terminalID: "term_123")
            )
        }
        #expect(await runner.commands().count == 1)
    }
}

private actor HerdrFixtureRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var history: [CommandSpec] = []

    init(outputs: [InventoryProcessOutput]) { self.outputs = outputs }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        history.append(command)
        guard !outputs.isEmpty else { throw HerdrError.malformedResponse }
        return outputs.removeFirst()
    }

    func commands() -> [CommandSpec] { history }
}
