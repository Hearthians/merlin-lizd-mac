import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Remote editor SSH bridge commands")
struct RemoteEditorBridgeCommandTests {
    @Test("optional registration preserves the command, quoting and exit status")
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
        #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
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
