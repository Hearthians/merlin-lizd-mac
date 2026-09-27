import Foundation

public enum SlurmServiceError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(exitCode: Int32, message: String)
    case transportUnavailable
    case submissionOutcomeUnknown(SlurmLaunchReceipt)
    case cancellationOutcomeUnknown(SlurmManagedJob)
    case ambiguousLaunch(SlurmLaunchReceipt)
    case jobUnavailable(SlurmJobID)
    case identityMismatch

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            message.isEmpty
                ? "Slurm 命令失败（退出码 \(exitCode)）。"
                : "Slurm 命令失败（退出码 \(exitCode)）：\(message)"
        case .transportUnavailable: "无法通过登录节点读取 Slurm。"
        case .submissionOutcomeUnknown:
            "启动连接在结果确认前中断。请按启动凭据查询，避免重复提交。"
        case .cancellationOutcomeUnknown:
            "取消连接在结果确认前中断。请刷新作业状态，避免重复取消。"
        case .ambiguousLaunch: "发现多个匹配同一启动凭据的作业，已停止自动操作。"
        case let .jobUnavailable(jobID): "作业 \(jobID.rawValue) 已不在活动队列中。"
        case .identityMismatch: "作业身份已经变化，已拒绝取消。"
        }
    }
}

protocol SlurmRemoteCommandRunning: Sendable {
    func run(
        _ command: CommandSpec,
        alias: String,
        replay: SSHReplayPolicy
    ) async throws -> InventoryProcessOutput
}

extension SSHMasterPool: SlurmRemoteCommandRunning {}

public actor SlurmService {
    private let remoteRunner: any SlurmRemoteCommandRunning

    public init(sshMasterPool: SSHMasterPool) {
        remoteRunner = sshMasterPool
    }

    init(remoteRunner: any SlurmRemoteCommandRunning) {
        self.remoteRunner = remoteRunner
    }

    public func listJobs(
        on platform: SlurmPlatformProfile
    ) async throws -> [SlurmJobSnapshot] {
        let command = try SlurmCommands.listJobs(platform: platform)
        let output = try await query(command, on: platform)
        return try SlurmParser.queue(output.stdout)
    }

    /// Performs exactly one non-replayed mutation. If the SSH result is
    /// uncertain, the error carries the receipt needed for reconciliation.
    public func startInteractive(
        on platform: SlurmPlatformProfile,
        preset: SlurmInteractivePreset,
        requestID: UUID = UUID(),
        requestedAt: Date = Date()
    ) async throws -> SlurmLaunchReceipt {
        let receipt = try SlurmCommands.launchReceipt(
            platform: platform,
            requestID: requestID,
            requestedAt: requestedAt
        )
        let command = try SlurmCommands.startInteractive(
            platform: platform,
            preset: preset,
            receipt: receipt
        )
        let output: InventoryProcessOutput
        do {
            output = try await remoteRunner.run(
                command,
                alias: platform.loginDestination,
                replay: .never
            )
        } catch {
            throw SlurmServiceError.submissionOutcomeUnknown(receipt)
        }
        guard output.exitCode == 0 else {
            throw commandError(output)
        }
        return receipt
    }

    /// Reconciliation is read-only and therefore may safely use SSH replay.
    public func reconcile(
        _ receipt: SlurmLaunchReceipt,
        on platform: SlurmPlatformProfile
    ) async throws -> SlurmReconciliation {
        try SlurmCommands.validate(receipt, for: platform)
        let jobs = try await listJobs(on: platform).filter {
            $0.owner == receipt.owner
                && $0.name == receipt.jobName
                && $0.comment == receipt.comment
        }
        guard jobs.count <= 1 else {
            throw SlurmServiceError.ambiguousLaunch(receipt)
        }
        guard let snapshot = jobs.first else { return .waiting(receipt) }
        return .found(SlurmManagedJob(receipt: receipt, snapshot: snapshot))
    }

    /// Re-reads the exact JobID and all ownership fields before issuing the
    /// guarded, non-replayed remote cancellation.
    public func cancel(
        _ managedJob: SlurmManagedJob,
        on platform: SlurmPlatformProfile
    ) async throws {
        try SlurmCommands.validate(managedJob.receipt, for: platform)
        let inspect = try SlurmCommands.inspectJob(
            platform: platform,
            jobID: managedJob.snapshot.jobID
        )
        let current = try SlurmParser.queue(try await query(inspect, on: platform).stdout)
        guard let snapshot = current.first(where: { $0.jobID == managedJob.snapshot.jobID }) else {
            throw SlurmServiceError.jobUnavailable(managedJob.snapshot.jobID)
        }
        guard current.count == 1,
            snapshot.owner == managedJob.receipt.owner,
            snapshot.name == managedJob.receipt.jobName,
            snapshot.comment == managedJob.receipt.comment
        else { throw SlurmServiceError.identityMismatch }

        let verified = SlurmManagedJob(receipt: managedJob.receipt, snapshot: snapshot)
        let command = try SlurmCommands.cancelVerified(
            platform: platform,
            managedJob: verified
        )
        let output: InventoryProcessOutput
        do {
            output = try await remoteRunner.run(
                command,
                alias: platform.loginDestination,
                replay: .never
            )
        } catch {
            throw SlurmServiceError.cancellationOutcomeUnknown(verified)
        }
        guard output.exitCode == 0 else {
            if output.exitCode == 74 { throw SlurmServiceError.identityMismatch }
            throw commandError(output)
        }
    }

    private func query(
        _ command: CommandSpec,
        on platform: SlurmPlatformProfile
    ) async throws -> InventoryProcessOutput {
        let output: InventoryProcessOutput
        do {
            output = try await remoteRunner.run(
                command,
                alias: platform.loginDestination,
                replay: .readOnly
            )
        } catch {
            throw SlurmServiceError.transportUnavailable
        }
        guard output.exitCode == 0 else { throw commandError(output) }
        return output
    }

    private func commandError(_ output: InventoryProcessOutput) -> SlurmServiceError {
        .commandFailed(
            exitCode: output.exitCode,
            message: Self.safeMessage(output.stderr)
        )
    }

    private static func safeMessage(_ value: String) -> String {
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        }))
        return String(filtered.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
    }
}
