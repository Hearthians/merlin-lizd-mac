import Foundation

public enum SlurmServiceError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(exitCode: Int32, message: String)
    case transportUnavailable
    case connectionFailed(message: String)
    case submissionOutcomeUnknown(SlurmLaunchReceipt)
    case cancellationOutcomeUnknown(SlurmManagedJob)
    case ambiguousLaunch(SlurmLaunchReceipt)
    case jobUnavailable(SlurmJobID)
    case identityMismatch
    case invalidMonitoringResponse

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            message.isEmpty
                ? "Slurm 命令失败（退出码 \(exitCode)）。"
                : "Slurm 命令失败（退出码 \(exitCode)）：\(message)"
        case .transportUnavailable: "无法通过登录节点读取 Slurm。"
        case let .connectionFailed(message):
            "\(connectionFailureSummary ?? "无法连接登录节点。")\n\n\(message)"
        case .submissionOutcomeUnknown:
            "启动连接在结果确认前中断。请按启动凭据查询，避免重复提交。"
        case .cancellationOutcomeUnknown:
            "取消连接在结果确认前中断。请刷新作业状态，避免重复取消。"
        case .ambiguousLaunch: "发现多个匹配同一启动凭据的作业，已停止自动操作。"
        case let .jobUnavailable(jobID): "作业 \(jobID.rawValue) 已不在活动队列中。"
        case .identityMismatch: "作业身份已经变化，已拒绝取消。"
        case .invalidMonitoringResponse: "Slurm 返回的监控数据不完整。"
        }
    }

    /// A short recovery hint for views that show the SSH diagnostic separately.
    public var connectionFailureSummary: String? {
        guard case let .connectionFailed(message) = self else { return nil }
        if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "登录节点的 SSH 主机密钥与本机记录不一致，连接已被 SSH 拒绝。请联系集群管理员核实主机指纹后，再更新本机主机记录。"
        }
        if message.contains("Host key verification failed") {
            return "登录节点的 SSH 身份尚未通过验证。请打开登录 Shell 查看详情，并核实服务器身份。"
        }
        if message.contains("Permission denied") {
            return "SSH 认证未通过。请打开登录 Shell 完成登录后重试。"
        }
        if message.localizedCaseInsensitiveContains("Could not resolve hostname")
            || message.localizedCaseInsensitiveContains("Temporary failure in name resolution") {
            return "无法解析 SSH 登录主机名。请检查当前网络或 DNS，并核对 SSH 配置中的 HostName。"
        }
        return "无法连接登录节点。请查看连接详情，或打开登录 Shell 检查。"
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

    public func jobHistory(
        on platform: SlurmPlatformProfile,
        range: SlurmHistoryRange = .month
    ) async throws -> [SlurmJobHistoryRecord] {
        let output = try await query(
            SlurmCommands.jobHistory(platform: platform, range: range), on: platform
        )
        return try SlurmHistoryParser.parse(output.stdout).filter {
            $0.snapshot.owner == platform.owner && $0.isFinished
        }
    }


    public func queueResources(
        on platform: SlurmPlatformProfile
    ) async throws -> [SlurmQueueSnapshot] {
        let output = try await query(
            SlurmCommands.queueResources(platform: platform), on: platform
        )
        let sections = try monitoringSections(output.stdout, markers: [
            SlurmCommands.monitoringNodesMarker,
            SlurmCommands.monitoringPartitionsMarker,
            SlurmCommands.monitoringQueueMarker,
            SlurmCommands.monitoringEndMarker,
        ])
        let queue = sections[2].contains(SlurmCommands.monitoringUnavailableMarker)
            ? nil : sections[2]
        return try SlurmMonitoringParser.queues(
            nodes: sections[0], partitions: sections[1], queue: queue, sampledAt: Date()
        )
    }

    /// Samples only the supplied user's active jobs. Accounting is read-only;
    /// at most three jobs get an overlapping GPU monitoring step per refresh.
    public func jobUtilization(
        on platform: SlurmPlatformProfile,
        jobs: [SlurmJobSnapshot]
    ) async throws -> [SlurmJobID: SlurmJobUtilizationSnapshot] {
        try SlurmCommands.validate(platform)
        let sampledAt = Date()
        var unique: [SlurmJobID: SlurmJobSnapshot] = [:]
        for job in jobs { unique[job.jobID] = job }
        let running = unique.values
            .filter {
                $0.owner == platform.owner && $0.state == .running
                    && SlurmCommands.isNumericMonitoringJobID($0.jobID)
            }
            .sorted { $0.jobID.rawValue < $1.jobID.rawValue }
        let sampledJobs = Array(running.prefix(64))
        var allocations: [SlurmJobID: SlurmJobAllocation] = [:]
        var statistics: [SlurmJobID: SlurmJobStatistics] = [:]
        if !sampledJobs.isEmpty {
            let command = try SlurmCommands.jobStatistics(
                platform: platform, jobIDs: sampledJobs.map(\.jobID)
            )
            let output = try await query(command, on: platform)
            let sections = try monitoringSections(output.stdout, markers: [
                SlurmCommands.monitoringAllocationsMarker,
                SlurmCommands.monitoringStatisticsMarker,
                SlurmCommands.monitoringEndMarker,
            ])
            allocations = try SlurmMonitoringParser.allocations(sections[0]).filter {
                unique[$0.key]?.owner == platform.owner && $0.value.owner == platform.owner
            }
            if !sections[1].contains(SlurmCommands.monitoringUnavailableMarker) {
                statistics = try SlurmMonitoringParser.statistics(
                    sections[1], allocations: allocations
                )
            }
        }

        var result: [SlurmJobID: SlurmJobUtilizationSnapshot] = [:]
        var gpuJobs: [SlurmJobID] = []
        for job in unique.values.sorted(by: { $0.jobID.rawValue < $1.jobID.rawValue }) {
            let allocation = allocations[job.jobID]
            let reason: String?
            var gpus: [SlurmGPUUtilization]?
            if job.owner != platform.owner {
                reason = "仅采集你本人任务的利用情况。"
            } else if !SlurmCommands.isNumericMonitoringJobID(job.jobID) {
                reason = "数组和异构任务暂不支持利用情况采样。"
            } else if job.state != .running {
                reason = "任务运行后可查看利用情况。"
            } else if let allocation, allocation.state == .running {
                if (allocation.allocatedNPU ?? 0) > 0, (allocation.allocatedGPU ?? 0) == 0 {
                    reason = "NPU 已分配；暂不支持 NPU 利用率、显存和功率采样。"
                } else if allocation.allocatedGPU == 0 {
                    gpus = []
                    reason = statistics[job.jobID] == nil
                        ? "暂时无法读取 CPU 和内存统计。" : nil
                } else if !(1...1024).contains(job.nodeCount) {
                    reason = "无法确认任务的有效节点数量。"
                } else if allocation.allocatedGPU == nil {
                    reason = "暂时无法读取已分配的 GPU 数量。"
                } else if gpuJobs.count >= 3 {
                    reason = "每次刷新最多采样 3 个任务的 GPU。"
                } else {
                    gpuJobs.append(job.jobID)
                    reason = nil
                }
            } else {
                reason = "暂时无法读取任务当前分配的资源。"
            }
            result[job.jobID] = SlurmJobUtilizationSnapshot(
                jobID: job.jobID, allocation: allocation,
                statistics: statistics[job.jobID], gpus: gpus,
                sampledAt: sampledAt, unavailableReason: reason
            )
        }
        let gpuResults = await withTaskGroup(
            of: (SlurmJobID, [SlurmGPUUtilization]?, String?).self,
            returning: [(SlurmJobID, [SlurmGPUUtilization]?, String?)].self
        ) { group in
            for jobID in gpuJobs {
                group.addTask {
                    let sample = await self.sampleGPU(jobID: jobID, on: platform)
                    return (jobID, sample.gpus, sample.reason)
                }
            }
            var samples: [(SlurmJobID, [SlurmGPUUtilization]?, String?)] = []
            for await sample in group { samples.append(sample) }
            return samples
        }
        try Task.checkCancellation()
        for (jobID, gpus, reason) in gpuResults {
            let allocation = allocations[jobID]
            var sampledGPUs = gpus
            var sampleReason = reason
            if let gpus, let expected = allocation?.allocatedGPU, gpus.count != expected {
                if gpus.count < expected {
                    let coverage = "仅读取到 \(gpus.count) / \(expected) 张 GPU；其余采样暂不可用，不代表未分配。"
                    sampleReason = [sampleReason, coverage].compactMap { $0 }.joined(separator: " ")
                } else {
                    sampledGPUs = nil
                    sampleReason = "GPU 采样数量与任务分配不一致，已忽略本次结果；下次刷新后重试。"
                }
            }
            if let gpus = sampledGPUs, let expectedNodes = unique[jobID]?.nodeCount, expectedNodes > 1 {
                let nodes = Set(gpus.compactMap(\.nodeName))
                if gpus.contains(where: { $0.nodeName == nil }) || nodes.count > expectedNodes {
                    sampledGPUs = nil
                    sampleReason = "GPU 采样缺少有效的节点归属，已忽略本次结果；下次刷新后重试。"
                } else if nodes.count < expectedNodes {
                    let coverage = "GPU 采样覆盖 \(nodes.count) / \(expectedNodes) 个节点。"
                    sampleReason = [sampleReason, coverage].compactMap { $0 }.joined(separator: " ")
                }
            }
            result[jobID] = SlurmJobUtilizationSnapshot(
                jobID: jobID, allocation: allocation,
                statistics: statistics[jobID], gpus: sampledGPUs,
                sampledAt: Date(), unavailableReason: sampleReason
            )
        }
        return result
    }

    private func sampleGPU(
        jobID: SlurmJobID,
        on platform: SlurmPlatformProfile
    ) async -> (gpus: [SlurmGPUUtilization]?, reason: String?) {
        do {
            let command = try SlurmCommands.jobGPUUtilization(
                platform: platform, jobID: jobID
            )
            // srun can return a failure after other nodes already produced valid
            // samples. Keep those readings and expose the incomplete refresh.
            let output = try await remoteRunner.run(
                command, alias: platform.loginDestination, replay: .never
            )
            if output.exitCode != 0, output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw commandError(output)
            }
            let gpus = try SlurmMonitoringParser.gpuUsage(output.stdout)
            guard !gpus.isEmpty else {
                return (nil, "未能读取任务已分配 GPU 的采样数据。")
            }
            let reason: String? = output.exitCode == 0 ? nil
                : "部分节点采样失败或超时，保留已读取的 GPU 数据；训练任务继续运行。"
            return (gpus, reason)
        } catch is CancellationError {
            return (nil, "采样已取消。")
        } catch let SlurmServiceError.commandFailed(exitCode, _) {
            switch exitCode {
            case 74: return (nil, "任务已结束或当前任务归属发生变化。")
            case 75: return (nil, "无法确认任务的节点信息。")
            case 78: return (nil, "Slurm 未提供有效的已分配 GPU 编号。")
            case 124, 137: return (nil, "GPU 采样超时，训练任务继续运行。")
            default: return (nil, "暂时无法在任务内启动 GPU 采样。")
            }
        } catch {
            return (nil, "GPU 监控连接暂时不可用。")
        }
    }

    private func monitoringSections(
        _ output: String,
        markers: [String]
    ) throws -> [String] {
        var sections = Array(repeating: "", count: markers.count - 1)
        var section = -1
        for line in output.components(separatedBy: "\n") {
            if section + 1 < markers.count, line == markers[section + 1] {
                section += 1
            } else if markers.contains(line)
                || (section < 0 && !line.isEmpty)
                || (section == sections.count && !line.isEmpty)
            {
                throw SlurmServiceError.invalidMonitoringResponse
            } else if section >= 0 && section < sections.count {
                sections[section] += line + "\n"
            }
        }
        guard section == sections.count else {
            throw SlurmServiceError.invalidMonitoringResponse
        }
        return sections
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
        on platform: SlurmPlatformProfile,
        replay: SSHReplayPolicy = .readOnly
    ) async throws -> InventoryProcessOutput {
        let output: InventoryProcessOutput
        do {
            output = try await remoteRunner.run(
                command,
                alias: platform.loginDestination,
                replay: replay
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let SSHMasterPoolError.connectionFailed(_, message) {
            let diagnostic = Self.safeMessage(message, limit: 4_096)
            throw diagnostic.isEmpty
                ? SlurmServiceError.transportUnavailable
                : SlurmServiceError.connectionFailed(message: diagnostic)
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

    private static func safeMessage(_ value: String, limit: Int = 512) -> String {
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        }))
        return String(filtered.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}
