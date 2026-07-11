import Testing
@testable import MerlinLizdCore

@Suite("Devbox lifecycle")
struct MerlinDevboxLifecycleTests {
    @Test("starts a Devbox through the shared bounded process runner")
    func startsDevbox() async throws {
        let runner = LifecycleRecordingProcessRunner(exitCode: 7)
        let lifecycle = try MerlinDevboxLifecycle(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let exitCode = try await lifecycle.start(sid: "dbx_133757")

        #expect(exitCode == 7)
        let command = try #require(await runner.recordedCommand())
        #expect(command.executable == "/Users/test/.merlin-cli/bin/merlin-cli")
        #expect(command.arguments == [
            "cpu-devbox", "instances", "start",
            "--control-plane", "cn",
            "--json", #"{"sid":"dbx_133757"}"#,
        ])
    }
}

private actor LifecycleRecordingProcessRunner: InventoryProcessRunning {
    private let exitCode: Int32
    private var command: CommandSpec?

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        self.command = command
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: exitCode)
    }

    func recordedCommand() -> CommandSpec? {
        command
    }
}
