import Testing
@testable import MerlinLizdCore

@Suite("Terminal command routing")
struct CommandBuilderTests {
    @Test("SwiftTerm command uses the shared interactive SSH transport")
    func buildsManagedSwiftTermCommand() throws {
        let directory = temporarySSHDirectory()
        let pool = SSHMasterPool(
            testDirectory: directory, runner: SSHMasterScriptedRunner()
        )
        let builder = ManagedTerminalCommandBuilder(sshMasterPool: pool)

        let command = try builder.swiftTermCommand(
            target: .devbox(
                sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
            ),
            sessionName: "mlz-shell"
        )
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")

        assertManagedInteractiveCommand(
            command, expectedPath: expectedPath
        )
    }

    @Test("external Terminal command uses the same interactive SSH transport")
    func buildsManagedExternalTerminalCommand() throws {
        let directory = temporarySSHDirectory()
        let pool = SSHMasterPool(
            testDirectory: directory, runner: SSHMasterScriptedRunner()
        )
        let builder = ManagedTerminalCommandBuilder(sshMasterPool: pool)

        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679", devboxName: "wt_hl",
            alias: "hl_gpu_2", workerID: "3960209"
        )
        let command = try builder.externalTerminalCommand(
            target: target,
            sessionName: "mlz-train"
        )
        let swiftTermCommand = try builder.swiftTermCommand(
            target: target,
            sessionName: "mlz-train"
        )
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")

        assertManagedInteractiveCommand(
            command, expectedPath: expectedPath
        )
        #expect(controlPaths(in: command) == controlPaths(in: swiftTermCommand))
        #expect(command.arguments.last?.contains("mlx worker login 3960209") == true)
    }

    private func assertManagedInteractiveCommand(
        _ command: CommandSpec,
        expectedPath: String
    ) {
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.contains("-tt"))
        #expect(command.arguments.contains("ServerAliveInterval=10"))
        #expect(command.arguments.contains("ServerAliveCountMax=3"))
        #expect(controlPaths(in: command) == ["ControlPath=\(expectedPath)"])
        #expect(command.arguments.last?.contains("tmux new-session -A") == true)
    }

    private func controlPaths(in command: CommandSpec) -> [String] {
        command.arguments.filter { $0.hasPrefix("ControlPath=") }
    }

    @Test("renders argv as one shell command without evaluating metacharacters")
    func safelyRendersArgumentArray() throws {
        let rendered = try ShellCommandRenderer.render(CommandSpec(
            executable: "/usr/bin/printf",
            arguments: ["%s", "it's $(not-a-command); $HOME"]
        ))

        #expect(rendered ==
            #"'/usr/bin/printf' '%s' 'it'\''s $(not-a-command); $HOME'"#)
    }

    @Test("passes the rendered command to osascript as argv")
    func buildsExternalTerminalLaunchCommand() throws {
        let launch = try ExternalTerminalLauncher.command(
            for: CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: ["hl_gpu_2", "echo $HOME"]
            )
        )

        #expect(launch.executable == "/usr/bin/osascript")
        #expect(launch.arguments.suffix(2) == [
            "--",
            "'/usr/bin/ssh' 'hl_gpu_2' 'echo $HOME'",
        ])
        #expect(!launch.arguments.dropLast().contains { $0.contains("hl_gpu_2") })
    }

    @Test("a Worker terminal enters through its parent Devbox and resumes tmux")
    func buildsWorkerTerminalCommand() throws {
        let command = try MerlinCommands.workerTerminal(
            alias: "hl_gpu_2",
            workerID: "3960209",
            sessionName: "merlin-lizd-train"
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "hl_gpu_2",
            "exec mlx worker login 3960209 -- tmux new-session -A -s merlin-lizd-train"
        ])
    }

    @Test("rejects shell metacharacters before building a remote command")
    func rejectsShellMetacharacters() {
        #expect(throws: CommandValidationError.invalidAlias) {
            try MerlinCommands.workerTerminal(
                alias: "hl_gpu_2;touch",
                workerID: "3960209",
                sessionName: "safe-name"
            )
        }
        #expect(throws: CommandValidationError.invalidSessionName) {
            try MerlinCommands.workerTerminal(
                alias: "hl_gpu_2",
                workerID: "3960209",
                sessionName: "unsafe$(id)"
            )
        }
    }

    @Test("a Devbox terminal connects directly and resumes tmux")
    func buildsDevboxTerminalCommand() throws {
        let command = try MerlinCommands.devboxTerminal(
            alias: "lq_gpu",
            sessionName: "merlin-lizd-shell"
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "lq_gpu",
            "exec tmux new-session -A -s merlin-lizd-shell"
        ])
    }

    @Test("starting a Devbox uses the CPU lifecycle command and an argument-safe JSON payload")
    func buildsStartDevboxCommand() throws {
        let command = try MerlinCommands.startDevbox(
            merlinCLIPath: "/Users/lizd/.merlin-cli/bin/merlin-cli",
            sid: "dbx_133757"
        )

        #expect(command.executable == "/Users/lizd/.merlin-cli/bin/merlin-cli")
        #expect(command.arguments == [
            "cpu-devbox", "instances", "start",
            "--control-plane", "cn",
            "--json", #"{"sid":"dbx_133757"}"#
        ])
    }

    @Test("lists platform Workers with an instance filter and cursor pagination")
    func buildsMerlinWorkerListCommand() throws {
        let firstPage = try MerlinCommands.listWorkers(
            merlinCLIPath: "/Users/lizd/.merlin-cli/bin/merlin-cli",
            instanceSID: "dbx_135679"
        )
        let nextPage = try MerlinCommands.listWorkers(
            merlinCLIPath: "/Users/lizd/.merlin-cli/bin/merlin-cli",
            instanceSID: "dbx_135679",
            pageSize: 20,
            pageToken: "opaque-cursor"
        )

        #expect(firstPage.executable == "/Users/lizd/.merlin-cli/bin/merlin-cli")
        #expect(firstPage.arguments == [
            "cpu-devbox", "workers", "list",
            "--control-plane", "cn",
            "--json", #"{"filter":{"instance_sid":"dbx_135679"},"page_size":100}"#,
        ])
        #expect(nextPage.arguments.last ==
            #"{"filter":{"instance_sid":"dbx_135679"},"page_size":20,"page_token":"opaque-cursor"}"#)
    }

    @Test("rejects an invalid platform Worker page size")
    func rejectsInvalidWorkerPageSize() {
        #expect(throws: CommandValidationError.invalidWorkerPageSize) {
            try MerlinCommands.listWorkers(
                merlinCLIPath: "/Users/lizd/.merlin-cli/bin/merlin-cli",
                instanceSID: "dbx_135679",
                pageSize: 0
            )
        }
    }

    @Test("lists tmux sessions inside a Worker without allocating an interactive terminal")
    func buildsWorkerTmuxListCommand() throws {
        let command = try MerlinCommands.listTmuxSessions(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            )
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "hl_gpu_2",
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux list-sessions -F#{session_name},#{session_id},#{session_created}"
        ])
    }

    @Test("Worker tmux warmup combines readiness and discovery in one login")
    func buildsWorkerTmuxWarmupCommand() throws {
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )

        let command = try MerlinCommands.warmWorker(target: target)
        let remote = try #require(command.arguments.last)

        #expect(remote.contains("mlx worker login 3966762 --"))
        #expect(remote.contains("printf \\\"__MLZ_READY__\\n\\\""))
        #expect(remote.contains(
            "tmux list-sessions -F#{session_name},#{session_id},#{session_created}"
        ))
        #expect(remote.components(separatedBy: "mlx worker login").count == 2)
        #expect(!remote.contains("new-session"))
        #expect(!remote.contains("attach"))
        #expect(!remote.contains("kill"))
    }

    @Test("Worker tmux warmup survives both shell parsing hops")
    func workerWarmupSurvivesTwoShellHops() async throws {
        let command = try MerlinCommands.warmWorker(target: .worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        ))
        let remote = try #require(command.arguments.last)
        let runner = FoundationInventoryProcessRunner()
        let devboxShell = """
        mlx() {
            while [ "$1" != "--" ]; do shift; done
            shift
            printf "%s\\n" "$*"
        }
        \(remote)
        """

        let devboxOutput = try await runner.run(.init(
            executable: "/bin/sh",
            arguments: ["-c", devboxShell]
        ))
        let reconstructed = devboxOutput.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        #expect(reconstructed ==
            #"sh -lc 'printf "__MLZ_READY__\n"; tmux list-sessions -F#{session_name},#{session_id},#{session_created}'"#)

        let directory = temporarySSHDirectory()
        _ = try await runner.run(.init(
            executable: "/bin/mkdir",
            arguments: [directory.path]
        ))
        let fakeTmux = """
        #!/bin/sh
        printf "__TMUX_ARGS__:%s\\n" "$*"
        printf "worker-session\\n"
        """
        let installFakeTmux = """
        printf "%s" '\(fakeTmux)' > \(directory.path)/tmux
        chmod 700 \(directory.path)/tmux
        printf "%s\\n" 'export PATH="\(directory.path):/usr/bin:/bin"' > \(directory.path)/.profile
        """
        _ = try await runner.run(.init(
            executable: "/bin/sh",
            arguments: ["-c", installFakeTmux]
        ))
        let workerOutput = try await runner.run(.init(
            executable: "/usr/bin/env",
            arguments: [
                "HOME=\(directory.path)",
                "PATH=\(directory.path):/usr/bin:/bin",
                "/bin/sh", "-c", reconstructed,
            ]
        ))
        _ = try await runner.run(.init(
            executable: "/bin/rm",
            arguments: ["-rf", directory.path]
        ))

        #expect(workerOutput.exitCode == 0)
        #expect(workerOutput.stdout.split(separator: "\n").map(String.init) == [
            "__MLZ_READY__",
            "__TMUX_ARGS__:list-sessions -F#{session_name},#{session_id},#{session_created}",
            "worker-session",
        ])
    }

    @Test("renames the selected Worker tmux session through its parent Devbox")
    func buildsWorkerTmuxRenameCommand() throws {
        let command = try MerlinCommands.renameTmuxSession(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            ),
            from: "mlz-old",
            to: "training-main"
        )

        #expect(command.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux rename-session -t mlz-old training-main")
    }

    @Test("renames a known Worker tmux session by its stable server ID")
    func buildsIdentityTargetedWorkerTmuxRenameCommand() throws {
        let command = try MerlinCommands.renameTmuxSession(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            ),
            from: "mlz-old",
            to: "training-main",
            identity: TmuxSessionIdentity(
                serverSessionID: "$3",
                createdAtEpoch: 100
            )
        )

        #expect(command.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux rename-session -t \"'\\$3'\" training-main")
    }

    @Test("Worker identity rename preserves the server ID through both shells")
    func identityRenameSurvivesWorkerShellHops() async throws {
        let command = try MerlinCommands.renameTmuxSession(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            ),
            from: "mlz-old",
            to: "training-main",
            identity: TmuxSessionIdentity(
                serverSessionID: "$3",
                createdAtEpoch: 100
            )
        )
        let remote = try #require(command.arguments.last)
        let runner = FoundationInventoryProcessRunner()
        let devboxShell = """
        mlx() {
            while [ "$1" != "--" ]; do shift; done
            shift
            printf "%s\\n" "$*"
        }
        \(remote)
        """
        let devboxOutput = try await runner.run(.init(
            executable: "/bin/sh",
            arguments: ["-c", devboxShell]
        ))
        let reconstructed = devboxOutput.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let directory = temporarySSHDirectory()
        _ = try await runner.run(.init(
            executable: "/bin/mkdir",
            arguments: [directory.path]
        ))
        let fakeTmux = """
        #!/bin/sh
        printf "__TMUX_ARGS__:%s\\n" "$*"
        """
        let installFakeTmux = """
        printf "%s" '\(fakeTmux)' > \(directory.path)/tmux
        chmod 700 \(directory.path)/tmux
        """
        _ = try await runner.run(.init(
            executable: "/bin/sh",
            arguments: ["-c", installFakeTmux]
        ))
        let workerOutput = try await runner.run(.init(
            executable: "/usr/bin/env",
            arguments: [
                "PATH=\(directory.path):/usr/bin:/bin",
                "/bin/sh", "-c", reconstructed,
            ]
        ))
        _ = try await runner.run(.init(
            executable: "/bin/rm",
            arguments: ["-rf", directory.path]
        ))

        #expect(workerOutput.stdout ==
            "__TMUX_ARGS__:rename-session -t $3 training-main\n")
    }

    @Test("rejects an unsafe tmux server ID in a rename selector")
    func rejectsUnsafeTmuxRenameIdentity() {
        #expect(throws: CommandValidationError.invalidTmuxSessionID) {
            try MerlinCommands.renameTmuxSession(
                target: .local,
                from: "mlz-old",
                to: "training-main",
                identity: TmuxSessionIdentity(
                    serverSessionID: "$3;touch-pwned",
                    createdAtEpoch: 100
                )
            )
        }
    }

    @Test("terminates one Worker tmux session through its parent Devbox")
    func buildsWorkerTmuxTerminationCommand() throws {
        let command = try MerlinCommands.terminateTmuxSession(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            ),
            sessionName: "mlz-finished-run"
        )

        #expect(command.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux kill-session -t mlz-finished-run")
    }

    @Test("rejects shell syntax in a tmux termination target")
    func rejectsUnsafeTmuxTermination() {
        #expect(throws: CommandValidationError.invalidSessionName) {
            try MerlinCommands.terminateTmuxSession(
                target: .devbox(
                    sid: "dbx_135679",
                    name: "wt_hl",
                    alias: "hl_gpu_2"
                ),
                sessionName: "mlz-old;rm"
            )
        }
    }

    @Test("rejects shell syntax in either tmux rename operand")
    func rejectsUnsafeTmuxRename() {
        let target = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: "hl_gpu_2"
        )

        #expect(throws: CommandValidationError.invalidSessionName) {
            try MerlinCommands.renameTmuxSession(
                target: target,
                from: "mlz-old;id",
                to: "training-main"
            )
        }
        #expect(throws: CommandValidationError.invalidSessionName) {
            try MerlinCommands.renameTmuxSession(
                target: target,
                from: "mlz-old",
                to: "$(touch-pwned)"
            )
        }
    }

    @Test("samples Worker metrics through the alias and mlx route only")
    func buildsWorkerMetricsCommand() throws {
        let command = try MerlinCommands.sampleWorkerMetrics(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3966762"
            )
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.dropLast() == [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "hl_gpu_2",
        ])
        let remoteCommand = try #require(command.arguments.last)
        #expect(remoteCommand.hasPrefix(
            "NO_COLOR=1 TERM=dumb mlx worker login 3966762 -- export LC_ALL=C \\;"
        ))
        #expect(remoteCommand.contains("head -n 1 /proc/stat"))
        #expect(remoteCommand.contains("cat /proc/meminfo"))
        #expect(remoteCommand.contains("/sys/fs/cgroup/cpu,cpuacct/cpuacct.usage"))
        #expect(remoteCommand.contains("/sys/fs/cgroup/memory/memory.usage_in_bytes"))
        #expect(remoteCommand.contains("/sys/fs/cgroup/cpu.stat"))
        #expect(remoteCommand.contains("/sys/fs/cgroup/memory.current"))
        #expect(remoteCommand.contains("nvidia-smi --query-gpu="))
        #expect(remoteCommand.contains("__MERLIN_LIZD_METRICS_V1_END__"))
        #expect(!remoteCommand.contains("podIP"))
        #expect(!remoteCommand.contains("ProxyCommand"))
        #expect(!remoteCommand.contains("9221"))
    }

    @Test("metrics sampling rejects non-Worker and unsafe Worker targets")
    func rejectsUnsafeMetricsTargets() {
        #expect(throws: CommandValidationError.workerTargetRequired) {
            try MerlinCommands.sampleWorkerMetrics(target: .local)
        }
        #expect(throws: CommandValidationError.invalidAlias) {
            try MerlinCommands.sampleWorkerMetrics(
                target: .worker(
                    devboxSID: "dbx_135679",
                    devboxName: "wt_hl",
                    alias: "hl_gpu_2;id",
                    workerID: "3966762"
                )
            )
        }
        #expect(throws: CommandValidationError.invalidWorkerID) {
            try MerlinCommands.sampleWorkerMetrics(
                target: .worker(
                    devboxSID: "dbx_135679",
                    devboxName: "wt_hl",
                    alias: "hl_gpu_2",
                    workerID: "3966762;id"
                )
            )
        }
    }

    @Test("builds a persistent metrics loop with keepalives and complete envelopes")
    func buildsWorkerMetricsStreamCommand() throws {
        let command = try MerlinCommands.streamWorkerMetrics(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3966762"
            ),
            intervalSeconds: 15
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.dropLast() == [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "hl_gpu_2",
        ])
        let remoteCommand = try #require(command.arguments.last)
        #expect(remoteCommand.hasPrefix(
            "NO_COLOR=1 TERM=dumb mlx worker login 3966762 -- export LC_ALL=C \\; while true \\; do "
        ))
        #expect(remoteCommand.contains(
            "__MERLIN_LIZD_METRICS_V1_END__ \\; sleep 15 \\; done"
        ))
        #expect(remoteCommand.contains("__MERLIN_LIZD_METRICS_V1_BEGIN__"))
    }

    @Test("rejects unsafe metrics stream intervals before command construction")
    func rejectsInvalidMetricsStreamIntervals() {
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )
        #expect(throws: CommandValidationError.invalidMetricsInterval) {
            try MerlinCommands.streamWorkerMetrics(
                target: target,
                intervalSeconds: 0
            )
        }
        #expect(throws: CommandValidationError.invalidMetricsInterval) {
            try MerlinCommands.streamWorkerMetrics(
                target: target,
                intervalSeconds: 3_601
            )
        }
    }

    @Test("builds exact current active tmux metadata commands for every route")
    func buildsCurrentTmuxSurfaceCommands() throws {
        let format = "#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}"
        let local = try MerlinCommands.currentTmuxSurface(
            target: .local,
            sessionName: "mlz-shell"
        )
        let devbox = try MerlinCommands.currentTmuxSurface(
            target: .devbox(
                sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
            ),
            sessionName: "mlz-shell"
        )
        let worker = try MerlinCommands.currentTmuxSurface(
            target: .worker(
                devboxSID: "dbx_135679", devboxName: "wt_hl",
                alias: "hl_gpu_2", workerID: "3960209"
            ),
            sessionName: "mlz-shell"
        )

        #expect(local == CommandSpec(
            executable: "/opt/homebrew/bin/tmux",
            arguments: [
                "display-message", "-p", "-t", "mlz-shell", "-F\(format)",
            ]
        ))
        #expect(devbox.arguments.last ==
            "tmux display-message -p -t mlz-shell -F\(format)")
        #expect(worker.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux display-message -p -t mlz-shell -F\(format)")
    }

    @Test("targets window navigation to the validated session")
    func buildsTmuxWindowSelectionCommands() throws {
        let target = TerminalTarget.devbox(
            sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
        )

        let next = try MerlinCommands.selectTmuxWindow(
            target: target,
            sessionName: "mlz-shell",
            selection: .nextWindow
        )
        let previous = try MerlinCommands.selectTmuxWindow(
            target: target,
            sessionName: "mlz-shell",
            selection: .previousWindow
        )
        let indexed = try MerlinCommands.selectTmuxWindow(
            target: .local,
            sessionName: "mlz-shell",
            selection: .windowIndex(2)
        )

        #expect(next.arguments.last == "tmux next-window -t mlz-shell")
        #expect(previous.arguments.last == "tmux previous-window -t mlz-shell")
        #expect(indexed.arguments == [
            "select-window", "-t", "mlz-shell:2",
        ])
    }

    @Test("targets directional and cyclic pane navigation from the verified pane")
    func buildsTmuxPaneSelectionCommands() throws {
        let directions: [(TmuxVisibleSelection, String)] = [
            (.paneLeft, "-L"),
            (.paneRight, "-R"),
            (.paneUp, "-U"),
            (.paneDown, "-D"),
        ]
        for (selection, flag) in directions {
            let command = try MerlinCommands.selectTmuxPane(
                target: .local,
                paneID: "%456",
                selection: selection
            )
            #expect(command.arguments == [
                "select-pane", "-t", "%456", flag,
            ])
        }

        let next = try MerlinCommands.selectTmuxPane(
            target: .local,
            paneID: "%456",
            selection: .nextPane
        )
        let previousWorker = try MerlinCommands.selectTmuxPane(
            target: .worker(
                devboxSID: "dbx_135679", devboxName: "wt_hl",
                alias: "hl_gpu_2", workerID: "3960209"
            ),
            paneID: "%456",
            selection: .previousPane
        )

        #expect(next.arguments == [
            "select-pane", "-t", "%456",
            ";", "select-pane", "-t", ":.+",
        ])
        #expect(previousWorker.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux select-pane -t %456 '\\;' select-pane -t :.-")
    }

    @Test("builds exact visible split inspection kill and restore commands")
    func buildsTemporaryTmuxPaneCommands() throws {
        let split = try MerlinCommands.splitTmuxPane(
            target: .local,
            paneID: "%456"
        )
        let inspect = try MerlinCommands.tmuxPaneSurface(
            target: .local,
            paneID: "%789"
        )
        let kill = try MerlinCommands.killTmuxPane(
            target: .devbox(
                sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
            ),
            paneID: "%789"
        )
        let restoreWindow = try MerlinCommands.restoreTmuxWindow(
            target: .local,
            windowID: "@123"
        )
        let restorePane = try MerlinCommands.restoreTmuxPane(
            target: .local,
            paneID: "%456"
        )

        #expect(split.arguments == [
            "split-window", "-t", "%456", "-P", "-F#{window_id},#{pane_id}",
        ])
        #expect(inspect.arguments == [
            "display-message", "-p", "-t", "%789",
            "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
        ])
        #expect(kill.arguments.last == "tmux kill-pane -t %789")
        #expect(restoreWindow.arguments == [
            "select-window", "-t", "@123",
        ])
        #expect(restorePane.arguments == [
            "select-pane", "-t", "%456",
        ])
        #expect(!kill.arguments.contains("-a"))
    }

    @Test("Worker structural formats and selectors survive both shell hops")
    func workerTmuxSurfaceCommandsSurviveTwoShellHops() async throws {
        let commands = [
            try MerlinCommands.currentTmuxSurface(
                target: workerTarget(), sessionName: "mlz-shell"
            ),
            try MerlinCommands.splitTmuxPane(
                target: workerTarget(), paneID: "%456"
            ),
            try MerlinCommands.selectTmuxPane(
                target: workerTarget(), paneID: "%456", selection: .nextPane
            ),
        ]
        let runner = FoundationInventoryProcessRunner()
        var reconstructed: [String] = []

        for command in commands {
            let remote = try #require(command.arguments.last)
            let output = try await runner.run(.init(
                executable: "/bin/sh",
                arguments: ["-c", """
                mlx() {
                    while [ "$1" != "--" ]; do shift; done
                    shift
                    printf "%s\\n" "$*"
                }
                \(remote)
                """]
            ))
            reconstructed.append(output.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
            ))
        }

        #expect(reconstructed == [
            "tmux display-message -p -t mlz-shell -F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            "tmux split-window -t %456 -P -F#{window_id},#{pane_id}",
            #"tmux select-pane -t %456 \; select-pane -t :.+"#,
        ])
    }

    @Test("rejects untyped tmux selectors and invalid selection families")
    func rejectsUnsafeTmuxSurfaceCommands() {
        #expect(throws: CommandValidationError.invalidSessionName) {
            try MerlinCommands.currentTmuxSurface(
                target: .local, sessionName: "mlz;id"
            )
        }
        #expect(throws: CommandValidationError.invalidTmuxPaneID) {
            try MerlinCommands.killTmuxPane(
                target: .local, paneID: "%2;kill"
            )
        }
        #expect(throws: CommandValidationError.invalidTmuxWindowID) {
            try MerlinCommands.restoreTmuxWindow(
                target: .local, windowID: "@2;kill"
            )
        }
        #expect(throws: CommandValidationError.invalidTmuxWindowIndex) {
            try MerlinCommands.selectTmuxWindow(
                target: .local,
                sessionName: "mlz-shell",
                selection: .windowIndex(-1)
            )
        }
        #expect(throws: CommandValidationError.invalidTmuxSelection) {
            try MerlinCommands.selectTmuxPane(
                target: .local,
                paneID: "%2",
                selection: .nextWindow
            )
        }
    }

    private func workerTarget() -> TerminalTarget {
        .worker(
            devboxSID: "dbx_135679", devboxName: "wt_hl",
            alias: "hl_gpu_2", workerID: "3960209"
        )
    }
}
