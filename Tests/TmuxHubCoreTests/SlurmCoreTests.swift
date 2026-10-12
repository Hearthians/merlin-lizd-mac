import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm managed interactive jobs")
struct SlurmCoreTests {
    private let platform = SlurmPlatformProfile(
        id: "hkust-hpc2",
        name: "HKUST HPC2",
        loginDestination: "hpc2",
        owner: "zli760"
    )

    private let preset = SlurmInteractivePreset(
        id: "debug-a40",
        name: "Debug A40",
        partition: "debug",
        cpusPerTask: 4,
        memoryMiB: 16 * 1_024,
        wallTime: SlurmWallTime(seconds: 30 * 60),
        gpu: SlurmGPURequest(type: "a40", count: 1),
        workingDirectory: "/home/zli760/project with ' quote",
        initializationScript: "source ~/.bashrc\nconda activate research"
    )

    @Test("wall time formatting is deterministic")
    func wallTime() {
        #expect(SlurmWallTime(seconds: 30 * 60).schedulerValue == "00:30:00")
        #expect(SlurmWallTime(seconds: 90_061).schedulerValue == "1-01:01:01")
    }

    @Test("fixed queue schema parses active jobs and preserves scheduler details")
    func queueParser() throws {
        let output = queueLine(
            jobID: "1042",
            name: "tmuxhub-aabbccdd",
            state: "RUNNING",
            reason: "gpu02",
            nodes: "1",
            nodeList: "gpu02",
            comment: "tmuxhub:1234"
        ) + "\n" + queueLine(
            jobID: "1043_7",
            name: "array-task",
            state: "PENDING",
            reason: "Resources",
            nodes: "2",
            nodeList: "N/A",
            comment: ""
        )
        let jobs = try SlurmParser.queue(output)
        #expect(jobs.count == 2)
        #expect(jobs[0].jobID.rawValue == "1042")
        #expect(jobs[0].state == .running)
        #expect(jobs[0].nodeList == "gpu02")
        #expect(jobs[1].jobID.rawValue == "1043_7")
        #expect(jobs[1].state == .pending)
        #expect(jobs[1].nodeList == nil)
    }

    @Test("queue parser rejects schema drift, duplicates, and delimiter injection")
    func parserRejectsAmbiguity() throws {
        #expect(throws: SlurmParserError.malformedRow(line: 1)) {
            try SlurmParser.queue("1\u{001F}too\u{001F}few")
        }
        let duplicate = queueLine(jobID: "42") + "\n" + queueLine(jobID: "42")
        #expect(throws: SlurmParserError.duplicateJobID(try #require(SlurmJobID(rawValue: "42")))) {
            try SlurmParser.queue(duplicate)
        }
        let pipe = try #require(SlurmParser.queue(queueLine(name: "allowed|name")).first)
        #expect(pipe.name == "allowed|name")
    }

    @Test("interactive launch is one detached login-node tmux owning srun")
    func launchCommand() throws {
        let requestID = try #require(UUID(uuidString: "5AF32F31-5318-4D1B-9789-33A736C5DBA7"))
        let receipt = try SlurmCommands.launchReceipt(
            platform: platform,
            requestID: requestID,
            requestedAt: Date(timeIntervalSince1970: 100)
        )
        let command = try SlurmCommands.startInteractive(
            platform: platform,
            preset: preset,
            receipt: receipt
        )
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.contains("hpc2"))
        #expect(command.arguments.contains("BatchMode=yes"))
        let remote = try #require(command.arguments.last)
        #expect(remote.contains("tmux new-session -d"))
        #expect(remote.contains("tmux has-session"))
        #expect(remote.contains("srun"))
        #expect(remote.contains("--pty"))
        #expect(remote.contains("--comment"))
        #expect(remote.contains("tmuxhub:5af32f31-5318-4d1b-9789-33a736c5dba7"))
        #expect(remote.contains("16384M"))
        #expect(remote.contains("gpu:a40:1"))
        #expect(remote.contains("project with"))
        #expect(remote.contains("conda activate research"))
        #expect(!remote.contains("; srun"))
    }

    @Test("queue queries expand job arrays before parsing")
    func queueQueriesExpandArrays() throws {
        let list = try SlurmCommands.listJobs(platform: platform)
        let inspect = try SlurmCommands.inspectJob(
            platform: platform,
            jobID: try #require(SlurmJobID(rawValue: "1043_7"))
        )
        let listRemoteCommand = try #require(list.arguments.last)
        let inspectRemoteCommand = try #require(inspect.arguments.last)
        #expect(listRemoteCommand.contains("'--array'"))
        #expect(inspectRemoteCommand.contains("'--array'"))
    }

    @Test("command builder rejects option and shell injection in structured fields")
    func rejectsInjection() throws {
        let badPlatform = SlurmPlatformProfile(
            id: "hkust", name: "HKUST", loginDestination: "-oProxyCommand=bad", owner: "zli760"
        )
        #expect(throws: SlurmCommandError.invalidPlatform) {
            try SlurmCommands.listJobs(platform: badPlatform)
        }
        let badPreset = SlurmInteractivePreset(
            id: "bad", name: "Bad", partition: "debug;scancel",
            cpusPerTask: 1, memoryMiB: 1_024,
            wallTime: SlurmWallTime(seconds: 60)
        )
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        #expect(throws: SlurmCommandError.invalidPreset) {
            try SlurmCommands.startInteractive(
                platform: platform, preset: badPreset, receipt: receipt
            )
        }
    }

    @Test("forged launch receipt is rejected before any remote command")
    func rejectsForgedReceiptBeforeMutation() async throws {
        let expected = try SlurmCommands.launchReceipt(
            platform: platform,
            requestID: try #require(UUID(
                uuidString: "5AF32F31-5318-4D1B-9789-33A736C5DBA7"
            ))
        )
        let forged = SlurmLaunchReceipt(
            requestID: expected.requestID,
            platformID: expected.platformID,
            loginDestination: expected.loginDestination,
            owner: expected.owner,
            jobName: "external-job",
            comment: "external:job",
            tmuxSessionName: "external-session",
            requestedAt: expected.requestedAt
        )
        let snapshot = try #require(SlurmParser.queue(queueLine(
            jobID: "606",
            name: forged.jobName,
            comment: forged.comment
        )).first)
        let runner = SlurmFixtureRunner(outputs: [])
        let service = SlurmService(remoteRunner: runner)

        await #expect(throws: SlurmCommandError.invalidReceipt) {
            try await service.cancel(
                SlurmManagedJob(receipt: forged, snapshot: snapshot),
                on: platform
            )
        }
        #expect(await runner.calls().isEmpty)
    }

    @Test("receipt validation rejects invalid time and platform identity")
    func validatesReceiptEnvelope() throws {
        let expected = try SlurmCommands.launchReceipt(platform: platform)
        let invalidTime = SlurmLaunchReceipt(
            requestID: expected.requestID,
            platformID: expected.platformID,
            loginDestination: expected.loginDestination,
            owner: expected.owner,
            jobName: expected.jobName,
            comment: expected.comment,
            tmuxSessionName: expected.tmuxSessionName,
            requestedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        #expect(throws: SlurmCommandError.invalidReceipt) {
            try SlurmCommands.validate(invalidTime, for: platform)
        }

        let wrongPlatform = SlurmLaunchReceipt(
            requestID: expected.requestID,
            platformID: "another-platform",
            loginDestination: expected.loginDestination,
            owner: expected.owner,
            jobName: expected.jobName,
            comment: expected.comment,
            tmuxSessionName: expected.tmuxSessionName,
            requestedAt: expected.requestedAt
        )
        #expect(throws: SlurmCommandError.invalidReceipt) {
            try SlurmCommands.validate(wrongPlatform, for: platform)
        }
    }

    @Test("service never replays start and reconciles by owner, name, and comment")
    func startAndReconcile() async throws {
        let requestID = try #require(UUID(uuidString: "5AF32F31-5318-4D1B-9789-33A736C5DBA7"))
        let expected = try SlurmCommands.launchReceipt(
            platform: platform, requestID: requestID, requestedAt: .init(timeIntervalSince1970: 100)
        )
        let runner = SlurmFixtureRunner(outputs: [
            .init(stdout: "", stderr: "", exitCode: 0),
            .init(stdout: queueLine(
                jobID: "909",
                name: expected.jobName,
                comment: expected.comment
            ), stderr: "", exitCode: 0),
        ])
        let service = SlurmService(remoteRunner: runner)
        let receipt = try await service.startInteractive(
            on: platform,
            preset: preset,
            requestID: requestID,
            requestedAt: .init(timeIntervalSince1970: 100)
        )
        #expect(receipt == expected)
        let reconciliation = try await service.reconcile(receipt, on: platform)
        guard case let .found(job) = reconciliation else {
            Issue.record("Expected a reconciled job")
            return
        }
        #expect(job.snapshot.jobID.rawValue == "909")
        let calls = await runner.calls()
        #expect(calls.count == 2)
        #expect(calls[0].replay == "never")
        #expect(calls[1].replay == "readOnly")
    }

    @Test("uncertain start exposes its durable receipt instead of retrying")
    func uncertainStart() async throws {
        let runner = SlurmFixtureRunner(outputs: [], failureAtCall: 0)
        let service = SlurmService(remoteRunner: runner)
        do {
            _ = try await service.startInteractive(
                on: platform,
                preset: preset,
                requestID: try #require(UUID(uuidString: "5AF32F31-5318-4D1B-9789-33A736C5DBA7"))
            )
            Issue.record("Expected an uncertain submission result")
        } catch let SlurmServiceError.submissionOutcomeUnknown(receipt) {
            #expect(receipt.comment.contains("5af32f31"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let calls = await runner.calls()
        #expect(calls.count == 1)
        #expect(calls[0].replay == "never")
    }

    @Test("cancel revalidates exact identity then performs one guarded mutation")
    func verifiedCancellation() async throws {
        let receipt = try SlurmCommands.launchReceipt(
            platform: platform,
            requestID: try #require(UUID(uuidString: "5AF32F31-5318-4D1B-9789-33A736C5DBA7"))
        )
        let jobID = try #require(SlurmJobID(rawValue: "808"))
        let line = queueLine(jobID: jobID.rawValue, name: receipt.jobName, comment: receipt.comment)
        let snapshot = try #require(SlurmParser.queue(line).first)
        let runner = SlurmFixtureRunner(outputs: [
            .init(stdout: line, stderr: "", exitCode: 0),
            .init(stdout: "", stderr: "", exitCode: 0),
        ])
        let service = SlurmService(remoteRunner: runner)
        try await service.cancel(
            SlurmManagedJob(receipt: receipt, snapshot: snapshot),
            on: platform
        )
        let calls = await runner.calls()
        #expect(calls.map(\.replay) == ["readOnly", "never"])
        let cancelScript = try #require(calls.last?.command.arguments.last)
        #expect(cancelScript.contains("scancel"))
        #expect(cancelScript.contains(jobID.rawValue))
        #expect(!cancelScript.contains("--jobid"))
        #expect(cancelScript.contains(receipt.owner))
        #expect(cancelScript.contains(receipt.jobName))
        #expect(cancelScript.contains(receipt.comment))
        #expect(cancelScript.contains("[ \"$#\" -eq 4 ]"))
        #expect(cancelScript.contains("exit 74"))
    }

    @Test("cancel refuses a reused or changed job without sending a mutation")
    func cancellationIdentityMismatch() async throws {
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        let original = try #require(SlurmParser.queue(queueLine(
            jobID: "707", name: receipt.jobName, comment: receipt.comment
        )).first)
        let changed = queueLine(
            jobID: "707", name: receipt.jobName, comment: "tmuxhub:some-other-request"
        )
        let runner = SlurmFixtureRunner(outputs: [
            .init(stdout: changed, stderr: "", exitCode: 0)
        ])
        let service = SlurmService(remoteRunner: runner)
        await #expect(throws: SlurmServiceError.identityMismatch) {
            try await service.cancel(
                SlurmManagedJob(receipt: receipt, snapshot: original),
                on: platform
            )
        }
        #expect(await runner.calls().count == 1)
    }

    @Test("uncertain cancellation performs one non-replayed mutation")
    func uncertainCancellation() async throws {
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        let line = queueLine(
            jobID: "505",
            name: receipt.jobName,
            comment: receipt.comment
        )
        let snapshot = try #require(SlurmParser.queue(line).first)
        let managedJob = SlurmManagedJob(receipt: receipt, snapshot: snapshot)
        let runner = SlurmFixtureRunner(
            outputs: [.init(stdout: line, stderr: "", exitCode: 0)],
            failureAtCall: 1
        )
        let service = SlurmService(remoteRunner: runner)

        do {
            try await service.cancel(managedJob, on: platform)
            Issue.record("Expected an uncertain cancellation result")
        } catch let SlurmServiceError.cancellationOutcomeUnknown(uncertainJob) {
            #expect(uncertainJob == managedJob)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let calls = await runner.calls()
        #expect(calls.count == 2)
        #expect(calls.map(\.replay) == ["readOnly", "never"])
    }

    private func queueLine(
        jobID: String = "123",
        name: String = "example",
        owner: String = "zli760",
        state: String = "PENDING",
        reason: String = "Resources",
        partition: String = "debug",
        nodes: String = "1",
        elapsed: String = "00:00",
        limit: String = "00:30:00",
        start: String = "N/A",
        submit: String = "2026-09-27T10:00:00",
        nodeList: String = "N/A",
        comment: String = ""
    ) -> String {
        [jobID, name, owner, state, reason, partition, nodes, elapsed, limit,
         start, submit, nodeList, comment].joined(separator: "\u{001F}")
    }
}

private actor SlurmFixtureRunner: SlurmRemoteCommandRunning {
    struct Call: Sendable {
        let command: CommandSpec
        let alias: String
        let replay: String
    }

    private var outputs: [InventoryProcessOutput]
    private let failureAtCall: Int?
    private var history: [Call] = []

    init(outputs: [InventoryProcessOutput], failureAtCall: Int? = nil) {
        self.outputs = outputs
        self.failureAtCall = failureAtCall
    }

    func run(
        _ command: CommandSpec,
        alias: String,
        replay: SSHReplayPolicy
    ) async throws -> InventoryProcessOutput {
        let policy: String
        switch replay {
        case .readOnly: policy = "readOnly"
        case .never: policy = "never"
        }
        history.append(.init(command: command, alias: alias, replay: policy))
        if failureAtCall == history.count - 1 { throw SlurmFixtureError.transport }
        guard !outputs.isEmpty else { throw SlurmFixtureError.missingOutput }
        return outputs.removeFirst()
    }

    func calls() -> [Call] { history }
}

private enum SlurmFixtureError: Error {
    case transport
    case missingOutput
}
