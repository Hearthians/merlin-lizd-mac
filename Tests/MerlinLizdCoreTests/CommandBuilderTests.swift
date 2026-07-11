import Testing
@testable import MerlinLizdCore

@Suite("Terminal command routing")
struct CommandBuilderTests {
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
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux list-sessions -F#{session_name}"
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
}
