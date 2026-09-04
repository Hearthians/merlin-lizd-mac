import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SSH and tmux command safety")
struct CommandTests {
    @Test("accepts common OpenSSH destinations and rejects argv injection")
    func validatesDestinations() {
        for value in [
            "prod", "prod.example.com", "lizd@gfyh.fun",
            "10.0.0.8", "lizd@2001:db8::8", "[2001:db8::8]",
        ] {
            #expect(IdentifierValidator.isSSHDestination(value))
        }
        for value in ["", "-oProxyCommand=id", "host name", "host;id", "host\nname"] {
            #expect(!IdentifierValidator.isSSHDestination(value))
        }
    }

    @Test("builds a direct interactive SSH tmux command")
    func buildsRemoteTerminal() throws {
        let command = try TmuxCommands.remoteTerminal(
            destination: "lizd@gfyh.fun",
            sessionName: "hub-main"
        )
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "lizd@gfyh.fun",
            "exec tmux new-session -A -s hub-main",
        ])
    }

    @Test("quotes a server session id when renaming remotely")
    func quotesIdentitySelector() throws {
        let command = try TmuxCommands.renameTmuxSession(
            target: .ssh(destination: "prod"),
            from: "old",
            to: "new",
            identity: .init(serverSessionID: "$3", createdAtEpoch: 100)
        )
        #expect(command.arguments.last == "tmux rename-session -t '$3' new")
    }

    @Test("rejects unsafe session names")
    func rejectsUnsafeSessionName() {
        #expect(throws: CommandValidationError.invalidSessionName) {
            try TmuxCommands.remoteTerminal(
                destination: "prod",
                sessionName: "unsafe$(id)"
            )
        }
    }

    @Test("renders Terminal app argv without evaluating shell syntax")
    func rendersExternalCommand() throws {
        let rendered = try ShellCommandRenderer.render(CommandSpec(
            executable: "/usr/bin/printf",
            arguments: ["%s", "it's $(not-a-command); $HOME"]
        ))
        #expect(rendered ==
            #"'/usr/bin/printf' '%s' 'it'\''s $(not-a-command); $HOME'"#)
    }

    @Test("adds an optional password fallback without exposing it in argv")
    func buildsPasswordFallback() throws {
        let directory = URL(fileURLWithPath: "/tmp/th-auth", isDirectory: true)
        let commands = SSHMasterCommands(directory: directory)
        let authentication = try #require(SSHPasswordAuthentication(
            password: "example password",
            askPassExecutable: "/tmp/TmuxHubAskPass"
        ))
        let base = try TmuxCommands.listTmuxSessions(
            target: .ssh(destination: "prod")
        )
        let managed = try commands.managed(
            base,
            alias: "prod",
            authentication: authentication
        )

        #expect(!managed.arguments.contains("BatchMode=yes"))
        #expect(managed.arguments.contains("BatchMode=no"))
        #expect(managed.arguments.contains(
            "PreferredAuthentications=publickey,keyboard-interactive,password"
        ))
        #expect(managed.environment["SSH_ASKPASS"] == "/tmp/TmuxHubAskPass")
        #expect(managed.environment["TMUXHUB_SSH_PASSWORD"] == "example password")
        #expect(!managed.arguments.contains("example password"))
        let rendered = try ShellCommandRenderer.render(managed)
        #expect(!rendered.contains("example password"))
    }

    @Test("keeps interactive SSH prompts enabled without a saved password")
    func preservesInteractiveAuthentication() throws {
        let directory = URL(fileURLWithPath: "/tmp/th-interactive", isDirectory: true)
        let commands = SSHMasterCommands(directory: directory)
        let base = try TmuxCommands.remoteTerminal(
            destination: "prod",
            sessionName: "main"
        )
        let managed = try commands.managed(base, alias: "prod")
        #expect(!managed.arguments.contains("BatchMode=yes"))
        #expect(managed.environment.isEmpty)
    }

    @Test("passes command-specific environment to child processes")
    func passesEnvironment() async throws {
        let output = try await FoundationInventoryProcessRunner().run(
            CommandSpec(
                executable: "/usr/bin/printenv",
                arguments: ["TMUXHUB_TEST_MARKER"],
                environment: ["TMUXHUB_TEST_MARKER": "available"]
            )
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout == "available\n")
    }
}

@Suite("OpenSSH config catalog")
struct SSHConfigCatalogTests {
    @Test("extracts only concrete Host entries")
    func parsesConcreteHosts() {
        let hosts = SSHConfigCatalog.parseHostDeclarations("""
        Host * !blocked staging-?
            ServerAliveInterval 20
        Host prod prod-gpu # selectable aliases
        Host "quoted-host"
        Match all
        """)
        #expect(hosts == ["prod", "prod-gpu", "quoted-host"])
    }

    @Test("follows Include globs and deduplicates hosts")
    func followsIncludes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent(".ssh", isDirectory: true)
        let includes = ssh.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: includes,
            withIntermediateDirectories: true
        )
        try "Host alpha\nInclude conf.d/*.conf\n".write(
            to: ssh.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try "Host beta alpha\n".write(
            to: includes.appendingPathComponent("hosts.conf"),
            atomically: true,
            encoding: .utf8
        )

        let hosts = SSHConfigCatalog(homeDirectory: root).load()
        #expect(hosts.map(\.destination) == ["alpha", "beta"])
    }

    @Test("orders recent hosts first and separates 3-day and 7-day boundaries")
    func groupsHostsByRecency() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let destinations = [
            "never-b", "day-7", "recent-2", "day-3",
            "recent-1", "recent-hours", "day-6", "never-a",
        ]
        let hosts = destinations.map {
            SSHHost(destination: $0, source: .configuration)
        }
        let sections = SSHHostRecencyOrganizer.sections(
            hosts: hosts,
            lastUsedAt: [
                "recent-hours": now.addingTimeInterval(-day / 2),
                "recent-1": now.addingTimeInterval(-day),
                "recent-2": now.addingTimeInterval(-2 * day),
                "day-3": now.addingTimeInterval(-3 * day),
                "day-6": now.addingTimeInterval(-6 * day),
                "day-7": now.addingTimeInterval(-7 * day),
            ],
            now: now
        )

        #expect(sections.map(\.bucket) == [
            .withinOneDay,
            .oneToThreeDays,
            .threeToSevenDays,
            .olderThanSevenDays,
            .neverUsed,
        ])
        #expect(sections[0].hosts.map(\.destination) == ["recent-hours"])
        #expect(sections[1].hosts.map(\.destination) == ["recent-1", "recent-2"])
        #expect(sections[2].hosts.map(\.destination) == ["day-3", "day-6"])
        #expect(sections[3].hosts.map(\.destination) == ["day-7"])
        #expect(sections[4].hosts.map(\.destination) == ["never-a", "never-b"])
    }
}

@Suite("tmux sessions")
struct TmuxSessionTests {
    @Test("parses stable identities and ignores diagnostics")
    func parsesSessions() {
        let sessions = TmuxSessionParser.parse("""
        main,$1,100
        build,$2,101
        warning: something happened
        """)
        #expect(sessions == [
            TmuxSessionRecord(
                name: "main",
                identity: .init(serverSessionID: "$1", createdAtEpoch: 100)
            ),
            TmuxSessionRecord(
                name: "build",
                identity: .init(serverSessionID: "$2", createdAtEpoch: 101)
            ),
        ])
    }

    @Test("terminal state round-trips generic SSH targets")
    func roundTripsState() throws {
        let state = TerminalState(
            selectedTabID: "tab",
            tabs: [TerminalTabRecord(
                id: "tab",
                title: "prod · main",
                target: .ssh(destination: "prod"),
                sessionName: "main",
                tmuxIdentity: .init(serverSessionID: "$1", createdAtEpoch: 100)
            )]
        )
        #expect(try TerminalStateCodec.decode(TerminalStateCodec.encode(state)) == state)
    }

    @Test("discovery treats an absent tmux server as an empty healthy result")
    func handlesNoServer() async {
        let runner = ScriptedRunner(outputs: [InventoryProcessOutput(
            stdout: "",
            stderr: "no server running on /tmp/tmux-501/default",
            exitCode: 1
        )])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            localTmuxPath: "/usr/bin/tmux"
        )
        let snapshot = await discovery.refresh(target: .local)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.readiness == .ready)
        #expect(snapshot.lastError == nil)
    }

    @Test("discovery coalesces concurrent refreshes")
    func coalescesRefreshes() async {
        let runner = ScriptedRunner(outputs: [InventoryProcessOutput(
            stdout: "main,$1,100\n",
            stderr: "",
            exitCode: 0
        )])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            localTmuxPath: "/usr/bin/tmux"
        )
        async let first = discovery.refresh(target: .local)
        async let second = discovery.refresh(target: .local)
        let values = await [first, second]
        #expect(values[0].sessions == values[1].sessions)
        #expect(await runner.runCount() == 1)
    }

    @Test("an in-flight refresh cannot undo a confirmed rename")
    func preservesMutationDuringRefresh() async {
        let runner = BlockingRefreshRunner()
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            localTmuxPath: "/usr/bin/tmux"
        )
        let initial = await discovery.refresh(target: .local)
        let identity = initial.sessions[0].identity

        let refresh = Task {
            await discovery.refresh(target: .local, lane: .foreground)
        }
        await runner.waitUntilSecondRunStarts()
        await discovery.recordRename(
            target: .local,
            from: "main",
            to: "renamed",
            identity: identity
        )
        await runner.releaseSecondRun()

        #expect(await refresh.value.sessions.map(\.name) == ["renamed"])
        #expect(await discovery.peekSnapshot(target: .local)?.sessions.map(\.name)
            == ["renamed"])
    }
}

private actor ScriptedRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var count = 0

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        count += 1
        return outputs.isEmpty
            ? InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
            : outputs.removeFirst()
    }

    func runCount() -> Int { count }
}

private actor BlockingRefreshRunner: InventoryProcessRunning {
    private var count = 0
    private var secondRunStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        count += 1
        if count == 2 {
            secondRunStarted = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return InventoryProcessOutput(
            stdout: "main,$1,100\n",
            stderr: "",
            exitCode: 0
        )
    }

    func waitUntilSecondRunStarts() async {
        while !secondRunStarted { await Task.yield() }
    }

    func releaseSecondRun() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
