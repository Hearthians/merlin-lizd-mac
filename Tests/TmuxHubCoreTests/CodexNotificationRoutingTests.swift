import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Codex notification routing")
struct CodexNotificationRoutingTests {
    private func event(hostname: String = "test-host", socket: String = "/tmp/tmux-501/default",
                       pane: String = "%3", pid: Int = 123, created: Int = 456) -> CodexNotificationEvent {
        CodexNotificationEvent(id: UUID().uuidString, sourceID: UUID().uuidString,
            kind: .turnCompleted, sessionID: "codex-thread", cwd: "/work", hostname: hostname,
            sequence: 1, timestamp: Date(), tmuxSession: "training", tmuxSessionID: "$1",
            tmuxSessionCreated: created, tmuxServerPID: pid, tmuxWindow: "@2", tmuxPane: pane,
            tmuxSocket: socket)
    }

    @Test("notification tabs retain exact server identity across app restart")
    func persistence() throws {
        let route = try CodexNotificationRoute(event: event())
        let tab = TerminalTabRecord(id: "tab", title: "notification", target: .ssh(destination: "lab"),
            sessionName: "training", tmuxLaunchMode: .attachOnly, notificationRoute: route)
        let state = TerminalState(selectedTabID: "tab", tabs: [tab])
        #expect(try TerminalStateCodec.decode(TerminalStateCodec.encode(state)) == state)
        #expect(!tab.allowsTmuxLifecycleMutation)
        #expect(!route.isSameSession(as: try CodexNotificationRoute(event: event(pid: 124))))
    }

    @Test("routing commands only attach and quote all remote payloads")
    func commandValidation() throws {
        let route = try CodexNotificationRoute(event: event(socket: "/tmp/a'b $(touch nope)/default"))
        let remote = try CodexNotificationRouting.command(route: route, target: .ssh(destination: "lab"), attach: true)
        #expect(remote.arguments.first == "-tt")
        #expect(remote.arguments.last?.contains("'\"'\"'") == true)
        let context = try CodexNotificationRouting.contextCommand(route: route, target: .ssh(destination: "lab"))
        #expect(context.arguments.first == "-nT")
        #expect(context.arguments.last?.hasSuffix("'context'") == true)
        #expect(!CodexNotificationRouting.script.contains("new-session"))
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try CodexNotificationRouting.command(route: route, target: .ssh(destination: "-oProxyCommand=bad"), attach: false)
        }
        #expect(throws: CodexNotificationRoutingError.self) {
            try CodexNotificationRoute(event: event(pane: "%3; kill-session"))
        }
    }

    @Test("attachment context follows the active pane on the verified socket without changing selection")
    func notificationAttachmentContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-route-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = directory.appendingPathComponent("calls")
        let fakeTmux = directory.appendingPathComponent("tmux")
        let fakeScript = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(calls.path)'
        [ "$1" = -S ] && [ "$2" = '/tmp/notification-only/socket' ] || exit 13
        [ "$3" = display-message ] && [ "$6" = '$1:' ] || exit 14
        printf '123\\t$1\\t456\\t%%9\\tcodex\\t/work/current pane\\n'
        """
        try Data(fakeScript.utf8).write(to: fakeTmux)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTmux.path)
        let runner = TimedInventoryProcessRunner(timeout: .seconds(10), underlying: FoundationInventoryProcessRunner())
        let hostOutput = try await runner.run(CommandSpec(executable: "/usr/bin/python3", arguments: ["-c", "import socket; print(socket.gethostname())"]))
        let host = hostOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for (hostname, pid, created, succeeds) in [(host, 123, 456, true), (host, 999, 456, false),
                                                  (host, 123, 999, false), ("wrong-host.invalid", 123, 456, false)] {
            try? FileManager.default.removeItem(at: calls)
            // The notification's original pane may have closed; context must use the
            // session's currently active pane instead, while retaining its identity guard.
            let route = try CodexNotificationRoute(event: event(hostname: hostname,
                socket: "/tmp/notification-only/socket", pane: "%999", pid: pid, created: created))
            let payload = String(decoding: try JSONEncoder().encode(route), as: UTF8.self)
            let output = try await runner.run(CommandSpec(executable: "/usr/bin/python3",
                arguments: ["-c", CodexNotificationRouting.script, payload, "context"],
                environment: ["PATH": directory.path + ":/usr/bin:/bin"]))
            let commands = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            #expect(!commands.contains("select-pane") && !commands.contains("select-window") && !commands.contains("attach-session"))
            #expect(output.exitCode == (succeeds ? 0 : (hostname != host ? 21 : 1)))
            if succeeds {
                let context = try AttachmentPaths.parseContext(output.stdout, target: .local, sessionName: route.sessionID)
                #expect(context.paneID == "%9")
                #expect(context.processName == "codex")
                #expect(context.workingDirectory == "/work/current pane")
                #expect(!commands.contains("%999"))
            } else {
                #expect(output.stdout.isEmpty)
            }
            if hostname != host { #expect(commands.isEmpty) }
        }
    }

    @Test("stale host or recycled server cannot focus any pane")
    func staleIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = directory.appendingPathComponent("calls")
        let fakeTmux = directory.appendingPathComponent("tmux")
        let fakeScript = """
        #!/bin/sh
        echo "$3" >> '\(calls.path)'
        if [ "$3" = display-message ]; then
            echo '123|$1|456|%3|@2'
        fi
        """
        try Data(fakeScript.utf8).write(to: fakeTmux)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTmux.path)
        let runner = TimedInventoryProcessRunner(timeout: .seconds(10), underlying: FoundationInventoryProcessRunner())
        let hostOutput = try await runner.run(CommandSpec(executable: "/usr/bin/python3", arguments: ["-c", "import socket; print(socket.gethostname())"]))
        let host = hostOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for (hostname, pid, expectedCalls) in [("wrong-host.invalid", 123, 0), (host, 999, 1), (host, 123, 3)] {
            try? FileManager.default.removeItem(at: calls)
            let route = try CodexNotificationRoute(event: event(hostname: hostname, pid: pid))
            let payload = String(decoding: try JSONEncoder().encode(route), as: UTF8.self)
            let output = try await runner.run(CommandSpec(executable: "/usr/bin/python3",
                arguments: ["-c", CodexNotificationRouting.script, payload, "focus"],
                environment: ["PATH": directory.path + ":/usr/bin:/bin"]))
            let lines = (try? String(contentsOf: calls, encoding: .utf8))?.split(separator: "\n").count ?? 0
            #expect(lines == expectedCalls)
            #expect(output.exitCode == (expectedCalls == 3 ? 0 : (hostname != host ? 21 : 1)))
        }
    }

    @Test("matching and mismatched cluster connections both persist an isolated verified node", arguments: [Int32(0), 21])
    func loginNodeRecovery(initialExit: Int32) async throws {
        let directory = URL(fileURLWithPath: "/tmp/th-route-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = LoginNodeRouteRunner(initialExit: initialExit)
        let pool = SSHMasterPool(testDirectory: directory, runner: runner, passwordProvider: { alias in
            alias == "my-cluster" ? SSHPasswordAuthentication(password: "fixture", askPassExecutable: "/test/askpass") : nil
        })
        let target = TerminalTarget.ssh(destination: "my-cluster")
        let original = try CodexNotificationRoute(event: event(hostname: "HPC4-Login-3"))
        let route = try await CodexNotificationRouting.resolveAndFocus(
            route: original, target: target, sshMasterPool: pool,
            propertiesReader: SSHHostPropertiesReader(runner: runner))
        let endpoint = try #require(route.sshEndpoint)
        #expect(endpoint.address == "10.120.81.43")
        #expect(endpoint.hostKeyAlias == "hpc4login.hpc.hkust-gz.edu.cn")
        #expect(endpoint.destination == "my-cluster")
        #expect(route.isSameSession(as: original))
        let restored = try JSONDecoder().decode(CodexNotificationRoute.self, from: JSONEncoder().encode(route))
        #expect(restored == route)

        let attach = try CodexNotificationRouting.managedAttachCommand(
            route: restored, target: target, sshMasterPool: pool)
        #expect(attach.arguments.contains("HostName=10.120.81.43"))
        #expect(attach.arguments.contains("HostKeyAlias=hpc4login.hpc.hkust-gz.edu.cn"))
        #expect(attach.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(attach.arguments.contains("my-cluster"))
        #expect(!attach.arguments.contains("-F"))
        let ordinary = try SSHMasterCommands(directory: directory).socketPath(alias: "my-cluster")
        #expect(!attach.arguments.contains("ControlPath=\(ordinary)"))
        let different = CodexNotificationSSHEndpoint(destination: "my-cluster", address: "10.120.81.41",
            hostKeyAlias: endpoint.hostKeyAlias)
        let otherSocket = try SSHMasterCommands(directory: directory, endpoint: different).socketPath(alias: "my-cluster")
        #expect(!attach.arguments.contains("ControlPath=\(otherSocket)"))

        let service = AttachmentTransferService(sshMasterPool: pool)
        let context = try await service.context(target: target, sessionName: "training", localDirectory: "/",
            notificationRoute: restored)
        #expect(context.sshEndpoint == endpoint)
        #expect(context.workingDirectory == "/work/node-three")
        let commands = await runner.commands()
        let pinnedPreparation = try #require(commands.first {
            $0.arguments.contains("-MNf") && $0.arguments.contains("HostName=10.120.81.43")
        })
        #expect(pinnedPreparation.environment["TMUXHUB_SSH_PASSWORD"] == "fixture")
        #expect(pinnedPreparation.arguments.firstIndex(of: "StrictHostKeyChecking=yes")!
            < pinnedPreparation.arguments.firstIndex(of: "StrictHostKeyChecking=accept-new")!)
        #expect(commands.contains { $0.arguments.last?.hasSuffix("'context'") == true
            && $0.arguments.contains("HostName=10.120.81.43") })
        await pool.shutdown()
        #expect(throws: SSHMasterPoolError.shuttingDown) { try pool.pinned(to: endpoint) }
    }

    @Test("node discovery never treats an arbitrary event hostname or public address as a destination")
    func boundedNodeDiscovery() throws {
        #expect(CodexNotificationSSHEndpoint.matches(loginHostname: "HPC4-Login-3",
            configuredHostname: "hpc4login.hpc.hkust-gz.edu.cn"))
        for name in ["evil.example", "HPC3-Login-3", "HPC4-Login-3.evil.example", "HPC4-Login-3;echo"] {
            #expect(!CodexNotificationSSHEndpoint.matches(loginHostname: name,
                configuredHostname: "hpc4login.hpc.hkust-gz.edu.cn"))
        }
        for address in ["203.0.113.1", "127.0.0.1", "10.1.2.3 -oProxyCommand=bad", "010.1.2.3"] {
            #expect(throws: CodexNotificationRoutingError.self) {
                try CodexNotificationRouting.parseEndpoints(
                    InventoryProcessOutput(stdout: "[\"\(address)\"]", stderr: "", exitCode: 0),
                    destination: "hpc4", configuredHostname: "hpc4login.hpc.hkust-gz.edu.cn")
            }
        }
        let route = try CodexNotificationRoute(event: event(hostname: "HPC4-Login-3"))
        let endpoint = CodexNotificationSSHEndpoint(destination: "hpc4", address: "10.120.81.43",
            hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
        #expect(throws: CodexNotificationRoutingError.self) {
            try CodexNotificationRouting.command(route: route.pinned(to: endpoint),
                target: .ssh(destination: "other"), attach: true)
        }
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(CodexNotificationRoute.self, from: data).sshEndpoint == nil)
    }

    @Test("observed HPC login names match only their configured cluster")
    func observedLoginHostnames() {
        let nodes = [
            ("hpc2", "mgmt-5"), ("hpc2", "HPC2-Login-1"),
            ("hpc3", "ACD-Login-3"), ("hpc3", "HPC3-Login-1"),
            ("hpc4", "HPC4-Login-1"), ("hpc4", "HPC4-Login-3"),
        ]
        for cluster in ["hpc2", "hpc3", "hpc4"] {
            let configured = "\(cluster)login.hpc.hkust-gz.edu.cn"
            for (owner, hostname) in nodes {
                #expect(CodexNotificationSSHEndpoint.matches(loginHostname: hostname,
                    configuredHostname: configured) == (owner == cluster))
                #expect(CodexNotificationSSHEndpoint.matches(loginHostname: hostname.uppercased(),
                    configuredHostname: configured.uppercased()) == (owner == cluster))
            }
            for name in ["mgmt-", "ACD-Login-", "ACD-Login-3.evil.example", "mgmt-5;echo",
                         "ACD-Login-1234", "mgmt-５", "gpu1-31"] {
                #expect(!CodexNotificationSSHEndpoint.matches(loginHostname: name,
                    configuredHostname: configured))
            }
        }
        #expect(!CodexNotificationSSHEndpoint.matches(loginHostname: "ACD-Login-3",
            configuredHostname: "hpc3login.hpc.hkust-gz.edu.cn.evil.example"))
    }

    @Test("correct node still rejects a stale server instead of falling back to its session name")
    func recoveredNodeStillChecksIdentity() async throws {
        let directory = URL(fileURLWithPath: "/tmp/th-stale-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = LoginNodeRouteRunner(pinnedExit: 1)
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)
        let route = try CodexNotificationRoute(event: event(hostname: "HPC4-Login-3"))
        await #expect(throws: CodexNotificationRoutingError.self) {
            try await CodexNotificationRouting.resolveAndFocus(route: route,
                target: .ssh(destination: "hpc4"), sshMasterPool: pool,
                propertiesReader: SSHHostPropertiesReader(runner: runner))
        }
        let commands = await runner.commands()
        #expect(!commands.contains { $0.arguments.last?.hasSuffix("'attach'") == true })
        await pool.shutdown()
    }
}

private actor LoginNodeRouteRunner: InventoryProcessRunning {
    private var history: [CommandSpec] = []
    private let pinnedExit: Int32
    private let initialExit: Int32
    init(pinnedExit: Int32 = 0, initialExit: Int32 = 21) {
        self.pinnedExit = pinnedExit
        self.initialExit = initialExit
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        history.append(command)
        if command.arguments.contains("-G") {
            return InventoryProcessOutput(stdout: "hostname hpc4login.hpc.hkust-gz.edu.cn\nuser testuser\nport 2222\nproxyjump configured-jump\n",
                stderr: "", exitCode: 0)
        }
        if command.arguments.contains("check") { return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255) }
        if command.arguments.last?.contains("socket.getaddrinfo") == true {
            return InventoryProcessOutput(stdout: "[\"10.120.81.43\"]", stderr: "", exitCode: 0)
        }
        if command.arguments.last?.hasSuffix("'focus'") == true {
            return InventoryProcessOutput(stdout: "", stderr: "",
                exitCode: command.arguments.contains("HostName=10.120.81.43") ? pinnedExit : initialExit)
        }
        if command.arguments.last?.hasSuffix("'context'") == true {
            return InventoryProcessOutput(stdout: "%3\tcodex\t/work/node-three\n", stderr: "", exitCode: 0)
        }
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }
    func commands() -> [CommandSpec] { history }
}
