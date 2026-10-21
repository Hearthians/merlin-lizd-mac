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
            #expect(output.exitCode == (succeeds ? 0 : 1))
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
            #expect(output.exitCode == (expectedCalls == 3 ? 0 : 1))
        }
    }
}
