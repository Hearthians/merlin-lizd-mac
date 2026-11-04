import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Herdr installation")
struct HerdrInstallationTests {
    @Test("stages the official installer and pins installation to the user directory")
    func commandSafety() throws {
        let local = try HerdrInstallationCommand.make(target: .local)
        #expect(local.executable == "/bin/sh")
        #expect(local.arguments.count == 3)
        let localScript = local.arguments[1]
        #expect(localScript.contains("curl -fsSL --output"))
        #expect(localScript.contains(HerdrInstallationCommand.installerURL))
        #expect(localScript.contains("HERDR_INSTALL_DIR=\"$HOME/.local/bin\""))
        #expect(localScript.contains("/bin/sh \"$tmuxhub_installer\""))
        #expect(!localScript.contains("install.sh | sh"))
        #expect(localScript.contains("test \"$tmuxhub_size\" -le 1048576"))
        #expect(localScript.contains("tmuxhub_existing=$(tmuxhub_find_herdr || true)"))
        #expect(
            localScript.range(of: "tmuxhub_existing=")!.lowerBound
                < localScript.range(of: "curl -fsSL")!.lowerBound
        )

        let remote = try HerdrInstallationCommand.make(
            target: .ssh(destination: "user+tag@build-host")
        )
        #expect(remote.executable == "/usr/bin/ssh")
        #expect(remote.arguments.prefix(5) == [
            "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        ])
        #expect(remote.arguments[5] == "user+tag@build-host")
        #expect(remote.arguments.last!.contains(HerdrInstallationCommand.installerURL))
        #expect(remote.arguments.last!.contains("exec /bin/sh -c"))

        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try HerdrInstallationCommand.make(
                target: .ssh(destination: "host; touch /tmp/no")
            )
        }
    }

    @Test("accepts only a complete verified installation result")
    func resultParsing() throws {
        let result = try HerdrInstallationResult.parse(
            "installer output\nTMUXHUB_HERDR_INSTALL_V1\therdr 0.9.0\n/home/me/.local/bin/herdr\n"
        )
        #expect(result == .init(
            executablePath: "/home/me/.local/bin/herdr",
            version: "herdr 0.9.0"
        ))
        for malformed in [
            "TMUXHUB_HERDR_INSTALL_V1\therdr 0.9.0\nrelative/herdr\n",
            "TMUXHUB_HERDR_INSTALL_V1\t\n/home/me/.local/bin/herdr\n",
            "TMUXHUB_HERDR_INSTALL_V1\therdr 0.9.0\n/home/me/.local/bin/herdr\ntrailing\n",
            "TMUXHUB_HERDR_INSTALL_V1\therdr\n/home/me/.local/bin/herdr\u{0000}\n",
        ] {
            #expect(throws: HerdrInstallationError.unexpectedResponse) {
                try HerdrInstallationResult.parse(malformed)
            }
        }
    }

    @Test("service reports the verified binary and preserves bounded diagnostics")
    func service() async throws {
        let successRunner = HerdrInstallationFixtureRunner(outputs: [
            .init(
                stdout: "TMUXHUB_HERDR_INSTALL_V1\therdr 1.2.3\n/home/user/.local/bin/herdr\n",
                stderr: "", exitCode: 0
            )
        ])
        let success = HerdrInstallationService(processRunner: successRunner)
        let result = try await success.install(on: .local)
        #expect(result.version == "herdr 1.2.3")
        #expect(await successRunner.commands().count == 1)

        let failureRunner = HerdrInstallationFixtureRunner(outputs: [
            .init(stdout: "", stderr: "curl: host unavailable\u{0000}", exitCode: 22)
        ])
        let failure = HerdrInstallationService(processRunner: failureRunner)
        await #expect(throws: HerdrInstallationError.commandFailed(
            exitCode: 22, detail: "curl: host unavailable"
        )) {
            try await failure.install(on: .local)
        }
    }
}

private actor HerdrInstallationFixtureRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var history: [CommandSpec] = []

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        history.append(command)
        return outputs.removeFirst()
    }

    func commands() -> [CommandSpec] { history }
}
