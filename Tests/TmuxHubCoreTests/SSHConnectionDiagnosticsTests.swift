import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SSH connection diagnostics in Slurm")
struct SSHConnectionDiagnosticsTests {
    private let platform = SlurmPlatformProfile(
        id: "hkust-hpc2",
        name: "HKUST HPC2",
        loginDestination: "hpc2",
        owner: "zli760"
    )

    private let fingerprint = "SHA256:fixture-host-key-fingerprint"

    private var hostKeyFailure: String {
        """
        @ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @
        The fingerprint for the ED25519 key sent by the remote host is
        \(fingerprint).
        Offending ECDSA key in /Users/example/.ssh/known_hosts:58
        Host key verification failed.
        """
    }

    @Test("failed master preparation preserves the host-key diagnostic and does not query Slurm")
    func preparationFailureReachesSlurm() async throws {
        let fixture = makeFixture([
            .failure(.check, "Control socket does not exist"),
            .failure(.prepare, hostKeyFailure),
        ])
        defer { fixture.removeDirectory() }

        do {
            _ = try await fixture.service.listJobs(on: platform)
            Issue.record("Expected the SSH host-key failure")
        } catch let error as SlurmServiceError {
            guard case let .connectionFailed(message) = error else {
                Issue.record("Expected the SSH diagnostic, got \(error)")
                return
            }
            #expect(message.contains(fingerprint))
            #expect(message.contains("known_hosts:58"))
            #expect(error.localizedDescription.contains("指纹"))
            #expect(error.localizedDescription.contains("管理员"))
        }

        #expect(await fixture.runner.operations() == [.check, .prepare])
        #expect(await fixture.runner.remainingSteps() == 0)
    }

    @Test("a successful preparation and later empty failure cannot reuse an old host-key diagnostic")
    func recoveryDiscardsOldDiagnostic() async throws {
        let fixture = makeFixture([
            .failure(.check, "No control socket"),
            .failure(.prepare, hostKeyFailure),
            .failure(.check, "No control socket"),
            .success(.prepare),
            .success(.remote),
            .success(.check),
            .failure(.remote, ""),
            .failure(.check, "No control socket"),
            .failure(.prepare, ""),
        ])
        defer { fixture.removeDirectory() }

        await #expect(throws: SlurmServiceError.self) {
            _ = try await fixture.service.listJobs(on: platform)
        }
        #expect(try await fixture.service.listJobs(on: platform).isEmpty)
        await #expect(throws: SlurmServiceError.transportUnavailable) {
            _ = try await fixture.service.listJobs(on: platform)
        }

        #expect(await fixture.runner.remainingSteps() == 0)
        #expect(await fixture.runner.operations().filter { $0 == .remote }.count == 2)
    }

    @Test("an exhausted read-only retry reports the final SSH failure")
    func finalRetryPreservesDiagnostic() async throws {
        let finalMessage = "Connection closed by hpc2login.example port 22"
        let fixture = makeFixture([
            .success(.check),
            .failure(.remote, "Broken pipe from the first attempt"),
            .success(.check),
            .failure(.remote, finalMessage),
        ])
        defer { fixture.removeDirectory() }

        await #expect(throws: SlurmServiceError.connectionFailed(message: finalMessage)) {
            _ = try await fixture.service.listJobs(on: platform)
        }
        #expect(await fixture.runner.operations() == [.check, .remote, .check, .remote])
        #expect(await fixture.runner.remainingSteps() == 0)
    }

    @Test("cancelling a queue read propagates cancellation without retrying")
    func queryCancellationIsNotTransportFailure() async throws {
        let fixture = makeFixture([
            .success(.check),
            .init(operation: .remote, outcome: .cancelled),
        ])
        defer { fixture.removeDirectory() }

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.service.listJobs(on: platform)
        }
        #expect(await fixture.runner.operations() == [.check, .remote])
        #expect(await fixture.runner.remainingSteps() == 0)
    }

    @Test("job cancellation preserves a preflight SSH failure and never sends scancel")
    func cancellationPreflightRetainsDiagnostic() async throws {
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        let row = [
            "808", receipt.jobName, platform.owner, "RUNNING", "gpu01", "debug",
            "1", "00:01", "00:30:00", "2026-09-29T10:00:00", "2026-09-29T09:59:00",
            "gpu01", receipt.comment,
        ].joined(separator: "\u{001F}")
        let snapshot = try #require(SlurmParser.queue(row).first)
        let fixture = makeFixture([
            .failure(.check, "No control socket"),
            .failure(.prepare, hostKeyFailure),
        ])
        defer { fixture.removeDirectory() }

        await #expect(throws: SlurmServiceError.connectionFailed(message: hostKeyFailure)) {
            try await fixture.service.cancel(
                SlurmManagedJob(receipt: receipt, snapshot: snapshot),
                on: platform
            )
        }
        #expect(await fixture.runner.operations() == [.check, .prepare])
        #expect(await fixture.runner.remainingSteps() == 0)
    }

    @Test("SSH diagnostics remove control characters and have a bounded size")
    func diagnosticsAreSanitizedAndBounded() async throws {
        let dirtyMessage = "  \u{0000}\u{0007}\u{001B}Host key verification failed.\r\n"
            + fingerprint + "\t\u{007F}\n" + String(repeating: "x", count: 6_000)
        let fixture = makeFixture([
            .failure(.check, "No control socket"),
            .failure(.prepare, dirtyMessage),
        ])
        defer { fixture.removeDirectory() }

        do {
            _ = try await fixture.service.listJobs(on: platform)
            Issue.record("Expected the sanitized diagnostic")
        } catch let SlurmServiceError.connectionFailed(message) {
            #expect(message.count <= 4_096)
            #expect(message.hasPrefix("Host key verification failed.\n"))
            #expect(message.contains(fingerprint))
            #expect(!message.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n"
            })
        }
        #expect(await fixture.runner.remainingSteps() == 0)
    }

    private func makeFixture(_ steps: [SSHDiagnosticStep]) -> SSHDiagnosticFixture {
        let directory = URL(fileURLWithPath: "/tmp/th-diag-\(UUID().uuidString.prefix(8))")
        let runner = SSHDiagnosticRunner(steps: steps)
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)
        return SSHDiagnosticFixture(
            directory: directory,
            runner: runner,
            service: SlurmService(sshMasterPool: pool)
        )
    }
}

private struct SSHDiagnosticFixture {
    let directory: URL
    let runner: SSHDiagnosticRunner
    let service: SlurmService

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum SSHDiagnosticOperation: Equatable, Sendable {
    case check
    case prepare
    case remote
}

private struct SSHDiagnosticStep: Sendable {
    enum Outcome: Sendable {
        case output(InventoryProcessOutput)
        case cancelled
    }

    let operation: SSHDiagnosticOperation
    let outcome: Outcome

    static func success(_ operation: SSHDiagnosticOperation) -> Self {
        .init(operation: operation, outcome: .output(.init(stdout: "", stderr: "", exitCode: 0)))
    }

    static func failure(_ operation: SSHDiagnosticOperation, _ message: String) -> Self {
        .init(operation: operation, outcome: .output(.init(stdout: "", stderr: message, exitCode: 255)))
    }
}

private actor SSHDiagnosticRunner: InventoryProcessRunning {
    private var steps: [SSHDiagnosticStep]
    private var history: [SSHDiagnosticOperation] = []

    init(steps: [SSHDiagnosticStep]) {
        self.steps = steps
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let operation: SSHDiagnosticOperation
        if command.arguments.contains("-O") && command.arguments.contains("check") {
            operation = .check
        } else if command.arguments.contains("-MNf") {
            operation = .prepare
        } else {
            operation = .remote
        }
        history.append(operation)
        guard !steps.isEmpty else {
            Issue.record("Unexpected SSH operation: \(operation)")
            throw SSHDiagnosticFixtureError.unexpectedCommand
        }
        let step = steps.removeFirst()
        #expect(step.operation == operation)
        guard step.operation == operation else {
            throw SSHDiagnosticFixtureError.unexpectedCommand
        }
        switch step.outcome {
        case let .output(output): return output
        case .cancelled: throw CancellationError()
        }
    }

    func operations() -> [SSHDiagnosticOperation] { history }
    func remainingSteps() -> Int { steps.count }
}

private enum SSHDiagnosticFixtureError: Error {
    case unexpectedCommand
}
