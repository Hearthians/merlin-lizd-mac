import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm accounting history")
struct SlurmHistoryTests {
    private let platform = SlurmPlatformProfile(
        id: "hkust-hpc2", name: "HKUST HPC2", loginDestination: "hpc2", owner: "zli760"
    )

    @Test("accounting includes external and array jobs with completion details")
    func parsesExternalJobs() throws {
        let records = try SlurmHistoryParser.parse([
            row(id: "110", state: "COMPLETED", end: "2026-10-18T12:00:00"),
            row(id: "111_4", state: "CANCELLED by 1001", end: "2026-10-19T12:00:00"),
        ].joined(separator: "\n"))
        #expect(records.map { $0.snapshot.jobID.rawValue } == ["111_4", "110"])
        #expect(records[0].snapshot.state == .cancelled)
        #expect(records.allSatisfy { $0.isFinished })
        #expect(records[0].snapshot.name == "external-training")
        #expect(records[0].snapshot.nodeList == "gpu1-36")
        #expect(records[0].snapshot.elapsed == "03:22:28")
        #expect(records[0].allocatedResources.contains("gres/gpu=4"))
    }

    @Test("requeued allocations remain distinct while repeated rows and steps do not duplicate jobs")
    func allocationIdentity() throws {
        let original = row(id: "110", submit: "2026-10-18T10:00:00")
        let requeued = row(id: "110", submit: "2026-10-19T10:00:00")
        let records = try SlurmHistoryParser.parse([
            original, original, requeued, row(id: "110.batch"), row(id: "110.extern"),
        ].joined(separator: "\n"))
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
    }

    @Test("unknown terminal states need an actual end time")
    func unknownTerminalState() throws {
        let records = try SlurmHistoryParser.parse([
            row(id: "110", state: "BOOT_FAIL", end: "2026-10-19T11:00:00"),
            row(id: "111", state: "REQUEUED", end: "Unknown"),
            row(id: "112", state: "RUNNING", end: "Unknown"),
        ].joined(separator: "\n"))
        #expect(records.filter(\.isFinished).map { $0.snapshot.jobID.rawValue } == ["110"])
    }

    @Test("malformed and oversized history is reported instead of silently truncated")
    func rejectsIncompleteHistory() throws {
        #expect(throws: SlurmParserError.malformedRow(line: 1)) {
            try SlurmHistoryParser.parse("110\u{001F}missing-fields")
        }
        #expect(throws: SlurmParserError.responseTooLarge) {
            try SlurmHistoryParser.parse(String(repeating: "x", count: 8 * 1_024 * 1_024 + 1))
        }
        #expect(try SlurmHistoryParser.parse("\n").isEmpty)
    }

    @Test("history command explicitly scopes accounting to the user and selected window")
    func boundedCommand() throws {
        for range in SlurmHistoryRange.allCases {
            let command = try SlurmCommands.jobHistory(platform: platform, range: range)
            let remote = try #require(command.arguments.last)
            #expect(command.executable == "/usr/bin/ssh")
            #expect(command.arguments.contains("BatchMode=yes"))
            #expect(remote.contains("sacct"))
            #expect(remote.contains("--allocations"))
            #expect(remote.contains("--array"))
            #expect(remote.contains("--duplicates"))
            #expect(remote.contains("--user"))
            #expect(remote.contains("zli760"))
            #expect(remote.contains("now-\(range.rawValue)days"))
            #expect(remote.contains("--endtime"))
            #expect(remote.contains("20s"))
            #expect(remote.contains("SLURM_TIME_FORMAT=standard"))
            #expect(!remote.contains("scancel"))
            #expect(!remote.contains("srun"))
        }
    }

    @Test("history service keeps only this user's finished allocations and is replayable read-only")
    func filtersOwnerAndCurrentJobs() async throws {
        let runner = HistoryFixtureRunner(output: InventoryProcessOutput(
            stdout: [
                row(id: "110"),
                row(id: "111", owner: "someone-else"),
                row(id: "112", state: "RUNNING", end: "Unknown"),
                row(id: "113", state: "PENDING", end: "Unknown"),
                row(id: "114", state: "TIMEOUT"),
            ].joined(separator: "\n"), stderr: "", exitCode: 0
        ))
        let service = SlurmService(remoteRunner: runner)
        let records = try await service.jobHistory(on: platform)
        #expect(Set(records.map { $0.snapshot.jobID.rawValue }) == ["110", "114"])
        #expect(await runner.replayPolicies() == ["readOnly"])
    }

    @Test("accounting unavailable is an error, not empty history")
    func unavailableAccounting() async throws {
        let runner = HistoryFixtureRunner(output: InventoryProcessOutput(
            stdout: "", stderr: "Slurm accounting storage is disabled", exitCode: 1
        ))
        let service = SlurmService(remoteRunner: runner)
        await #expect(throws: SlurmServiceError.self) {
            try await service.jobHistory(on: platform)
        }
    }

    private func row(
        id: String,
        owner: String = "zli760",
        state: String = "COMPLETED",
        submit: String = "2026-10-18T10:00:00",
        end: String = "2026-10-19T12:00:00"
    ) -> String {
        [
            id, "external-training", owner, state, "gpu", "1", "03:22:28", "1-00:00:00",
            submit, submit, end, "gpu1-36", "0:0", "cpu=32,mem=256G,gres/gpu=4", "",
        ].joined(separator: SlurmCommands.fieldDelimiter)
    }
}

private actor HistoryFixtureRunner: SlurmRemoteCommandRunning {
    let output: InventoryProcessOutput
    private var policies: [String] = []

    init(output: InventoryProcessOutput) { self.output = output }

    func run(_ command: CommandSpec, alias: String, replay: SSHReplayPolicy) async throws -> InventoryProcessOutput {
        switch replay {
        case .readOnly: policies.append("readOnly")
        case .never: policies.append("never")
        }
        return output
    }

    func replayPolicies() -> [String] { policies }
}
