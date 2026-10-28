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

    @Test("classifies literal addresses without treating aliases as IPs")
    func classifiesIPAddressDestinations() {
        for value in [
            "10.0.0.8", "lizd@10.0.0.8", "2001:db8::8",
            "[2001:db8::8]", "lizd@[fe80::1%en0]",
        ] {
            #expect(IdentifierValidator.isIPAddressDestination(value))
        }
        for value in ["prod", "prod.example.com", "lizd@gfyh.fun", "host:22"] {
            #expect(!IdentifierValidator.isIPAddressDestination(value))
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

    @Test("attach-only terminals select an exact existing tmux session")
    func buildsAttachOnlyRemoteTerminal() throws {
        let command = try TmuxCommands.remoteTerminal(
            destination: "hpc2",
            sessionName: "tmuxhub-job-123",
            launchMode: .attachOnly
        )
        #expect(command.arguments.last ==
            "exec tmux attach-session -t =tmuxhub-job-123")
        #expect(!command.arguments.last!.contains("new-session"))
    }

    @Test("normalizes dotted session names without broadening accepted input")
    func normalizesSessionNames() {
        #expect(IdentifierValidator.normalizedTmuxSessionName(
            "hub-zhuodongli-10.30.45.144-d9823c18"
        ) == "hub-zhuodongli-10_30_45_144-d9823c18")
        #expect(IdentifierValidator.normalizedTmuxSessionName("hub-main_1") == "hub-main_1")
        let maximumLengthName = "a" + String(repeating: ".", count: 63)
        #expect(IdentifierValidator.normalizedTmuxSessionName(maximumLengthName)
            == "a" + String(repeating: "_", count: 63))
        for value in ["", ".main", "-main", "main:1", "main;id", "main\n", "main name",
                      String(repeating: "a", count: 65)] {
            #expect(IdentifierValidator.normalizedTmuxSessionName(value) == nil)
        }
    }

    @Test("builds a stable bounded session name for quick connect")
    func buildsStableSessionNames() throws {
        let first = try #require(IdentifierValidator.stableTmuxSessionName(
            for: "zhuodongli@10.30.45.144"
        ))
        let repeated = try #require(IdentifierValidator.stableTmuxSessionName(
            for: "zhuodongli@10.30.45.144"
        ))
        let other = try #require(IdentifierValidator.stableTmuxSessionName(
            for: "zhuodongli@10.30.45.145"
        ))

        #expect(first == repeated)
        #expect(first != other)
        #expect(first.hasPrefix("tmuxhub-zhuodongli-10_30_45_144-"))
        #expect(first.count <= 64)
        #expect(IdentifierValidator.stableTmuxSessionName(for: "host name") == nil)
    }

    @Test("uses tmux's stored session name for connection and mutation commands")
    func normalizesSessionCommandArguments() throws {
        let original = "hub-zhuodongli-10.30.45.144-d9823c18"
        let normalized = "hub-zhuodongli-10_30_45_144-d9823c18"
        let terminal = try TmuxCommands.remoteTerminal(
            destination: "zhuodongli@10.30.45.144", sessionName: original
        )
        #expect(terminal.arguments.last == "exec tmux new-session -A -s \(normalized)")
        #expect(terminal.arguments.contains("zhuodongli@10.30.45.144"))
        let termination = try TmuxCommands.terminateTmuxSession(
            target: .local, sessionName: original
        )
        #expect(termination.arguments == ["kill-session", "-t", normalized])
        let rename = try TmuxCommands.renameTmuxSession(
            target: .ssh(destination: "prod"), from: original, to: "new.name"
        )
        #expect(rename.arguments.last == "tmux rename-session -t \(normalized) new_name")
        let identityRename = try TmuxCommands.renameTmuxSession(
            target: .ssh(destination: "prod"), from: original, to: "new.name",
            identity: .init(serverSessionID: "$3", createdAtEpoch: 100)
        )
        #expect(identityRename.arguments.last == "tmux rename-session -t '$3' new_name")
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

    @Test("managed commands never query Keychain credentials synchronously")
    func preparedCommandsAvoidPasswordLookup() async throws {
        let counter = LockedCounter()
        let runner = ScriptedRunner(outputs: [
            .init(stdout: "", stderr: "", exitCode: 0), // master check
            .init(stdout: "", stderr: "", exitCode: 0), // remote command
        ])
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-no-password-requery"),
            runner: runner,
            passwordProvider: { _ in
                counter.increment()
                return nil
            }
        )
        let command = try TmuxCommands.listTmuxSessions(
            target: .ssh(destination: "prod")
        )
        let output = try await pool.run(command, alias: "prod", replay: .readOnly)
        #expect(output.exitCode == 0)
        #expect(counter.value == 0)

        _ = try pool.managedCommand(command, alias: "prod")
        #expect(counter.value == 0)
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

    @Test("quick access contains every pin and only a bounded recent set")
    func organizesQuickAccessHosts() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let hosts = [
            "pinned-unused", "pinned-recent", "recent-a", "recent-b",
            "recent-c", "expired", "never",
        ].map { SSHHost(destination: $0, source: .configuration) }

        let sections = SSHHostQuickAccessOrganizer.sections(
            hosts: hosts,
            pinnedDestinations: ["pinned-unused", "pinned-recent"],
            lastUsedAt: [
                "pinned-recent": now.addingTimeInterval(-day),
                "recent-a": now.addingTimeInterval(-day / 2),
                "recent-b": now.addingTimeInterval(-day),
                "recent-c": now.addingTimeInterval(-2 * day),
                "expired": now.addingTimeInterval(-8 * day),
            ],
            now: now,
            recentLimit: 2
        )

        #expect(sections.map(\.bucket) == [.pinned, .recent])
        #expect(sections[0].hosts.map(\.destination) == [
            "pinned-recent", "pinned-unused",
        ])
        #expect(sections[1].hosts.map(\.destination) == ["recent-a", "recent-b"])
    }

    @Test("quick access expires the seven-day boundary and honors a zero limit")
    func appliesRecentBoundaryAndLimit() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let hosts = ["inside", "boundary"].map {
            SSHHost(destination: $0, source: .configuration)
        }
        let lastUsedAt = [
            "inside": now.addingTimeInterval(-7 * day + 1),
            "boundary": now.addingTimeInterval(-7 * day),
        ]

        let visible = SSHHostQuickAccessOrganizer.sections(
            hosts: hosts,
            pinnedDestinations: [],
            lastUsedAt: lastUsedAt,
            now: now
        )
        #expect(visible.count == 1)
        #expect(visible[0].hosts.map(\.destination) == ["inside"])

        let limited = SSHHostQuickAccessOrganizer.sections(
            hosts: hosts,
            pinnedDestinations: [],
            lastUsedAt: lastUsedAt,
            now: now,
            recentLimit: 0
        )
        #expect(limited.isEmpty)
    }

    @Test("first migration pins named custom targets but leaves IPs transient")
    func migratesInitialPins() {
        let pins = SSHHostQuickAccessOrganizer.initialPins(
            customDestinations: [
                "prod", "lizd@example.com", "10.0.0.8", "lizd@10.0.0.8",
            ]
        )
        #expect(pins == ["prod", "lizd@example.com"])
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

    @Test("terminal state preserves attach-only tabs and defaults legacy tabs")
    func preservesTmuxLaunchMode() throws {
        let legacy = #"{"selectedTabID":"old","tabs":[{"id":"old","title":"Old","target":{"ssh":{"destination":"hpc2"}},"sessionName":"main"}]}"#
        let legacyState = try TerminalStateCodec.decode(legacy)
        #expect(legacyState.tabs[0].tmuxLaunchMode == .createOrAttach)
        #expect(legacyState.tabs[0].allowsTmuxLifecycleMutation)

        let managedState = TerminalState(
            selectedTabID: "managed",
            tabs: [.init(
                id: "managed",
                title: "HPC task 123",
                target: .ssh(destination: "hpc2"),
                sessionName: "tmuxhub-job-123",
                tmuxLaunchMode: .attachOnly
            )]
        )
        let restored = try TerminalStateCodec.decode(
            TerminalStateCodec.encode(managedState)
        )
        #expect(restored == managedState)
        #expect(restored.tabs[0].tmuxLaunchMode == .attachOnly)
        #expect(!restored.tabs[0].allowsTmuxLifecycleMutation)
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

    @Test("discovery treats a missing remote tmux socket as an empty healthy result")
    func handlesMissingRemoteSocket() async {
        let runner = ScriptedRunner(outputs: [InventoryProcessOutput(
            stdout: "",
            stderr: "error connecting to /tmp//tmux-14461/default (No such file or directory)",
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
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
