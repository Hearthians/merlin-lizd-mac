import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Remote editor SSH bridge commands")
struct RemoteEditorBridgeCommandTests {
    @Test("automatic setup failure preserves the command, quoting and exit status")
    func registrationFailureDoesNotPreventTerminalLaunch() throws {
        let original = CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-tt", "example", "printf '%s' 'original command: spaces and $sign'; exit 7",
        ], environment: ["TMUXHUB_TEST_VALUE": "preserved"])
        let wrapped = try RemoteEditorBridge.wrap(command: original, token: UUID().uuidString,
                                                 deviceName: "Mac'; printf injected; echo '")
        #expect(wrapped.environment == original.environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(wrapped.arguments.last)]
        // With no tty registration must fail harmlessly before writing any registry.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 7)
        #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                == "original command: spaces and $sign")
        let warning = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(warning.contains("automatic code setup failed"))
        #expect(!warning.contains("injected"))
    }

    @Test("a real SSH tty installs code before starting the Bash login shell")
    func automaticSetupBeforeShell() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-auto-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let original = CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-tt", "example",
            #"test -f "$HOME/.local/share/tmuxhub/remote-editor/bridge.py" && /bin/bash -lc 'declare -F code >/dev/null && printf TMUXHUB_CODE_READY'"#,
        ])
        let wrapped = try RemoteEditorBridge.wrap(command: original, token: UUID().uuidString,
                                                 deviceName: "Mac's Laptop")
        let runner = TimedInventoryProcessRunner(timeout: .seconds(15), underlying: FoundationInventoryProcessRunner())
        let output = try await runner.run(CommandSpec(executable: "/usr/bin/script",
            arguments: ["-q", "/dev/null", "/bin/sh", "-c", try #require(wrapped.arguments.last)],
            environment: ["HOME": home.path, "TERM": "xterm-256color",
                          "SSH_CONNECTION": "127.0.0.1 12345 127.0.0.1 22"]))
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("TMUXHUB_CODE_READY"))
        #expect(!output.stdout.contains("automatic code setup failed"))
        let profile = try String(contentsOf: home.appendingPathComponent(".profile"), encoding: .utf8)
        #expect(profile.contains("TmuxHub remote editor"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
    }

    @Test("local processes and invalid connection tokens cannot be wrapped")
    func rejectsInvalidInputs() throws {
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try RemoteEditorBridge.wrap(command: CommandSpec(executable: "/bin/sh", arguments: ["-l"]),
                                        token: UUID().uuidString, deviceName: "Mac")
        }
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try RemoteEditorBridge.wrap(command: CommandSpec(executable: "/usr/bin/ssh", arguments: ["-tt", "host", "exec tmux"]),
                                        token: "invalid-token", deviceName: "Mac")
        }
    }
}
