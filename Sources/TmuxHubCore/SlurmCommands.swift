import Foundation

public enum SlurmCommandError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlatform
    case invalidPreset
    case invalidReceipt
    case invalidJobIdentity

    public var errorDescription: String? {
        switch self {
        case .invalidPlatform: "Slurm 平台配置无效。"
        case .invalidPreset: "Slurm 资源预设包含无效值。"
        case .invalidReceipt: "任务启动凭据无效或不属于当前平台。"
        case .invalidJobIdentity: "Slurm 作业身份无效。"
        }
    }
}

public enum SlurmCommands {
    /// Parser and command builder share this fixed schema. Generated names and
    /// comments exclude the delimiter, and malformed external rows are rejected.
    static let fieldDelimiter = "\u{001F}"
    static let queueFormat = ["%i", "%j", "%u", "%T", "%R", "%P", "%D", "%M", "%l", "%S", "%V", "%N", "%k"]
        .joined(separator: fieldDelimiter)

    public static func listJobs(platform: SlurmPlatformProfile) throws -> CommandSpec {
        try validate(platform)
        return try remoteQuery(
            platform: platform,
            remoteArguments: [
                "squeue", "--noheader", "--array", "--user", platform.owner,
                "--format", queueFormat,
            ]
        )
    }

    public static func inspectJob(
        platform: SlurmPlatformProfile,
        jobID: SlurmJobID
    ) throws -> CommandSpec {
        try validate(platform)
        return try remoteQuery(
            platform: platform,
            remoteArguments: [
                "squeue", "--noheader", "--array", "--jobs", jobID.rawValue,
                "--format", queueFormat,
            ]
        )
    }


    // These markers form a private transport envelope; parser inputs remain the
    // unmodified output of the three scheduler tools.
    static let monitoringNodesMarker = "@@TMUXHUB_NODES@@"
    static let monitoringPartitionsMarker = "@@TMUXHUB_PARTITIONS@@"
    static let monitoringQueueMarker = "@@TMUXHUB_QUEUE@@"
    static let monitoringAllocationsMarker = "@@TMUXHUB_ALLOCATIONS@@"
    static let monitoringStatisticsMarker = "@@TMUXHUB_STATISTICS@@"
    static let monitoringEndMarker = "@@TMUXHUB_END@@"
    static let monitoringUnavailableMarker = "@@TMUXHUB_UNAVAILABLE@@"
    static let statisticsFormat =
        "JobID,NTasks,AveCPU,AveRSS,MaxRSS,TRESUsageInAve,TRESUsageInMax,TRESUsageInTot"

    /// One bounded, read-only request. Counts describe allocation, not activity.
    public static func queueResources(
        platform: SlurmPlatformProfile
    ) throws -> CommandSpec {
        let script = """
            printf '%s\\n' \(shellQuote(monitoringNodesMarker))
            scontrol show nodes --oneliner || exit 74
            printf '%s\\n' \(shellQuote(monitoringPartitionsMarker))
            scontrol show partitions --oneliner || exit 74
            printf '%s\\n' \(shellQuote(monitoringQueueMarker))
            if ! squeue --noheader --array --format '%P|%T'; then
                printf '%s\\n' \(shellQuote(monitoringUnavailableMarker))
            fi
            printf '%s\\n' \(shellQuote(monitoringEndMarker))
            """
        return try boundedMonitoringQuery(platform: platform, script: script, seconds: 12)
    }

    /// Allocation and accounting are read-only; no monitoring step is created.
    public static func jobStatistics(
        platform: SlurmPlatformProfile,
        jobIDs: [SlurmJobID]
    ) throws -> CommandSpec {
        try validate(platform)
        guard !jobIDs.isEmpty, jobIDs.count <= 64,
            Set(jobIDs).count == jobIDs.count,
            jobIDs.allSatisfy(isNumericMonitoringJobID)
        else { throw SlurmCommandError.invalidJobIdentity }
        let identifiers = jobIDs.map(\.rawValue)
        let statistics = shellJoin([
            "sstat", "--allsteps", "--noheader", "--parsable2",
            "--jobs", identifiers.joined(separator: ","),
            "--format", statisticsFormat,
        ])
        let script = """
            printf '%s\\n' \(shellQuote(monitoringAllocationsMarker))
            for tmuxhub_job in \(shellJoin(identifiers)); do
                scontrol show job "$tmuxhub_job" --oneliner || :
            done
            printf '%s\\n' \(shellQuote(monitoringStatisticsMarker))
            if ! \(statistics); then
                printf '%s\\n' \(shellQuote(monitoringUnavailableMarker))
            fi
            printf '%s\\n' \(shellQuote(monitoringEndMarker))
            """
        return try boundedMonitoringQuery(platform: platform, script: script, seconds: 12)
    }

    /// This creates only a short step inside a freshly verified existing own
    /// allocation. Callers must use SSHReplayPolicy.never for this command.
    public static func jobGPUUtilization(
        platform: SlurmPlatformProfile,
        jobID: SlurmJobID
    ) throws -> CommandSpec {
        try validate(platform)
        guard isNumericMonitoringJobID(jobID) else {
            throw SlurmCommandError.invalidJobIdentity
        }
        let verification = shellJoin([
            "squeue", "--noheader", "--array", "--jobs", jobID.rawValue,
            "--format", "%i %u %T %D",
        ])
        let gpuScript = #"""
            set -ef
            tmuxhub_ids=${SLURM_STEP_GPUS:-}
            [ -n "$tmuxhub_ids" ] || exit 78
            [ "${#tmuxhub_ids}" -le 16384 ] || exit 78
            [[ "$tmuxhub_ids" =~ ^[0-9]{1,4}(-[0-9]{1,4})?(,[0-9]{1,4}(-[0-9]{1,4})?)*$ ]] || exit 78
            IFS=',' read -r -a tmuxhub_parts <<< "$tmuxhub_ids"
            tmuxhub_expanded=
            tmuxhub_count=0
            for tmuxhub_part in "${tmuxhub_parts[@]}"; do
                [[ "$tmuxhub_part" =~ ^[0-9]{1,4}(-[0-9]{1,4})?$ ]] || exit 78
                tmuxhub_first=${tmuxhub_part%%-*}
                tmuxhub_last=${tmuxhub_part##*-}
                tmuxhub_first=$((10#$tmuxhub_first))
                tmuxhub_last=$((10#$tmuxhub_last))
                (( tmuxhub_first <= tmuxhub_last && tmuxhub_last <= 1023 )) || exit 78
                for ((tmuxhub_gpu=tmuxhub_first; tmuxhub_gpu<=tmuxhub_last; tmuxhub_gpu++)); do
                    case ",$tmuxhub_expanded," in *",$tmuxhub_gpu,"*) exit 78 ;; esac
                    tmuxhub_expanded="${tmuxhub_expanded:+$tmuxhub_expanded,}$tmuxhub_gpu"
                    tmuxhub_count=$((tmuxhub_count + 1))
                    [ "$tmuxhub_count" -le 1024 ] || exit 78
                done
            done
            [ -n "$tmuxhub_expanded" ] || exit 78
            exec nvidia-smi --id="$tmuxhub_expanded" --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits
            """#
        let step = shellJoin([
            "srun", "--jobid", jobID.rawValue, "--overlap", "--immediate=3",
            "--nodes=1", "--ntasks=1", "--cpus-per-task=1", "--cpu-bind=none",
            "--job-name=tmuxhub-monitor", "--chdir=/tmp",
            "/bin/bash", "-c", gpuScript,
        ])
        let script = """
            set -f
            tmuxhub_identity=$(\(verification)) || exit 74
            set -- $tmuxhub_identity
            [ "$#" -eq 4 ] || exit 74
            [ "$1" = \(shellQuote(jobID.rawValue)) ] || exit 74
            [ "$2" = \(shellQuote(platform.owner)) ] || exit 74
            [ "$3" = RUNNING ] || exit 74
            [ "$4" = 1 ] || exit 75
            exec \(step)
            """
        return try boundedMonitoringQuery(platform: platform, script: script, seconds: 15)
    }

    // Slurm exposes array/heterogeneous IDs differently in squeue, scontrol and
    // sstat. Until those identities are reconciled, exclude them from sampling
    // so one unsupported ID cannot invalidate accounting for normal jobs.
    static func isNumericMonitoringJobID(_ jobID: SlurmJobID) -> Bool {
        !jobID.rawValue.isEmpty && jobID.rawValue.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func boundedMonitoringQuery(
        platform: SlurmPlatformProfile,
        script: String,
        seconds: Int
    ) throws -> CommandSpec {
        try remoteShell(
            platform: platform,
            script: "exec " + shellJoin([
                "timeout", "--signal=TERM", "--kill-after=2s", "\(seconds)s",
                "/bin/bash", "-c", script,
            ]),
            interactive: false
        )
    }



    public static func launchReceipt(
        platform: SlurmPlatformProfile,
        requestID: UUID = UUID(),
        requestedAt: Date = Date()
    ) throws -> SlurmLaunchReceipt {
        try validate(platform)
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SlurmCommandError.invalidReceipt
        }
        let identity = launchIdentity(for: requestID)
        return SlurmLaunchReceipt(
            requestID: requestID,
            platformID: platform.id,
            loginDestination: platform.loginDestination,
            owner: platform.owner,
            jobName: identity.jobName,
            comment: identity.comment,
            tmuxSessionName: identity.tmuxSessionName,
            requestedAt: requestedAt
        )
    }

    /// Starts one detached login-node tmux session. The session owns `srun`, so
    /// an app or SSH disconnect cannot terminate the interactive allocation.
    public static func startInteractive(
        platform: SlurmPlatformProfile,
        preset: SlurmInteractivePreset,
        receipt: SlurmLaunchReceipt
    ) throws -> CommandSpec {
        try validate(platform)
        try validate(preset)
        try validate(receipt, for: platform)

        var srun = [
            "srun",
            "--job-name", receipt.jobName,
            "--comment", receipt.comment,
            "--partition", preset.partition,
            "--ntasks", String(preset.tasks),
            "--cpus-per-task", String(preset.cpusPerTask),
            "--mem", "\(preset.memoryMiB)M",
            "--time", preset.wallTime.schedulerValue,
        ]
        if let gpu = preset.gpu {
            let resource = ["gpu", gpu.type, String(gpu.count)]
                .compactMap { $0 }
                .joined(separator: ":")
            srun += ["--gres", resource]
        }
        if let workingDirectory = preset.workingDirectory {
            srun += ["--chdir", workingDirectory]
        }
        srun.append("--pty")

        if let initializationScript = preset.initializationScript {
            let loginScript = initializationScript + "\nexec /bin/bash -l"
            srun += ["/bin/bash", "-lc", loginScript]
        } else {
            srun += ["/bin/bash", "-l"]
        }

        let srunScript = "exec " + shellJoin(srun)
        let target = "=" + receipt.tmuxSessionName
        let script = """
            command -v tmux >/dev/null 2>&1 || exit 127
            command -v srun >/dev/null 2>&1 || exit 127
            if tmux has-session -t \(shellQuote(target)) 2>/dev/null; then exit 73; fi
            exec tmux new-session -d -s \(shellQuote(receipt.tmuxSessionName)) /bin/bash -lc \(shellQuote(srunScript))
            """
        return try remoteShell(platform: platform, script: script, interactive: false)
    }

    public static func attachInteractive(
        platform: SlurmPlatformProfile,
        receipt: SlurmLaunchReceipt
    ) throws -> CommandSpec {
        try validate(platform)
        try validate(receipt, for: platform)
        let script = "exec tmux attach-session -t " + shellQuote("=" + receipt.tmuxSessionName)
        return try remoteShell(platform: platform, script: script, interactive: true)
    }

    /// The remote guard reads all four identity fields immediately before
    /// `scancel`. A stale or hand-constructed identity exits without mutation.
    static func cancelVerified(
        platform: SlurmPlatformProfile,
        managedJob: SlurmManagedJob
    ) throws -> CommandSpec {
        try validate(platform)
        try validate(managedJob.receipt, for: platform)
        let snapshot = managedJob.snapshot
        guard snapshot.owner == managedJob.receipt.owner,
            snapshot.name == managedJob.receipt.jobName,
            snapshot.comment == managedJob.receipt.comment
        else { throw SlurmCommandError.invalidJobIdentity }

        // These four managed identity values are validated whitespace-free.
        // Let the POSIX shell discard squeue's presentation padding, while the
        // exact field count rejects an empty response or multiple matching rows.
        let verificationFormat = "%i %u %j %k"
        let query = shellJoin([
            "squeue", "--noheader", "--jobs", snapshot.jobID.rawValue,
            "--format", verificationFormat,
        ])
        let script = """
            set -f
            tmuxhub_identity=$(\(query)) || exit 74
            set -- $tmuxhub_identity
            [ "$#" -eq 4 ] || exit 74
            [ "$1" = \(shellQuote(snapshot.jobID.rawValue)) ] || exit 74
            [ "$2" = \(shellQuote(managedJob.receipt.owner)) ] || exit 74
            [ "$3" = \(shellQuote(managedJob.receipt.jobName)) ] || exit 74
            [ "$4" = \(shellQuote(managedJob.receipt.comment)) ] || exit 74
            exec scancel \(shellQuote(snapshot.jobID.rawValue))
            """
        return try remoteShell(platform: platform, script: script, interactive: false)
    }

    static func validate(_ platform: SlurmPlatformProfile) throws {
        guard SlurmValidation.isSafeIdentifier(platform.id),
            !platform.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            platform.name.utf8.count <= 256,
            IdentifierValidator.isSSHDestination(platform.loginDestination),
            SlurmValidation.isSafeIdentifier(platform.owner)
        else { throw SlurmCommandError.invalidPlatform }
    }

    static func validate(_ preset: SlurmInteractivePreset) throws {
        guard SlurmValidation.isSafeIdentifier(preset.id),
            !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            preset.name.utf8.count <= 256,
            SlurmValidation.isSafeIdentifier(preset.partition),
            (1...4_096).contains(preset.tasks),
            (1...4_096).contains(preset.cpusPerTask),
            (1...1_073_741_824).contains(preset.memoryMiB),
            (1...31_536_000).contains(preset.wallTime.seconds)
        else { throw SlurmCommandError.invalidPreset }
        if let gpu = preset.gpu {
            guard (1...1_024).contains(gpu.count),
                gpu.type.map({ SlurmValidation.isSafeIdentifier($0) }) ?? true
            else { throw SlurmCommandError.invalidPreset }
        }
        if let path = preset.workingDirectory,
            !SlurmValidation.isAbsolutePath(path)
        { throw SlurmCommandError.invalidPreset }
        if let script = preset.initializationScript,
            !SlurmValidation.isScript(script)
        { throw SlurmCommandError.invalidPreset }
    }

    static func validate(
        _ receipt: SlurmLaunchReceipt,
        for platform: SlurmPlatformProfile
    ) throws {
        let identity = launchIdentity(for: receipt.requestID)
        guard receipt.platformID == platform.id,
            receipt.loginDestination == platform.loginDestination,
            receipt.owner == platform.owner,
            receipt.jobName == identity.jobName,
            receipt.comment == identity.comment,
            receipt.tmuxSessionName == identity.tmuxSessionName,
            receipt.requestedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw SlurmCommandError.invalidReceipt }
    }

    private static func launchIdentity(
        for requestID: UUID
    ) -> (jobName: String, comment: String, tmuxSessionName: String) {
        let token = requestID.uuidString.lowercased()
        let shortToken = token.replacingOccurrences(of: "-", with: "").prefix(16)
        return (
            jobName: "tmuxhub-\(shortToken)",
            comment: "tmuxhub:\(token)",
            tmuxSessionName: "tmuxhub-slurm-\(shortToken)"
        )
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func shellJoin(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    private static func remoteQuery(
        platform: SlurmPlatformProfile,
        remoteArguments: [String]
    ) throws -> CommandSpec {
        try remoteShell(
            platform: platform,
            script: "exec " + shellJoin(remoteArguments),
            interactive: false
        )
    }

    private static func remoteShell(
        platform: SlurmPlatformProfile,
        script: String,
        interactive: Bool
    ) throws -> CommandSpec {
        try validate(platform)
        let options = interactive
            ? ["-tt", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
            : ["-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: options + [
                platform.loginDestination,
                loginShell(script: script),
            ]
        )
    }

    /// Slurm is added to PATH by the cluster's login profile. Keep profile
    /// banners on stderr so stdout remains a machine-readable queue response.
    /// The pane launched in an existing tmux server also needs its own login
    /// shell, since that server may still hold the old PATH.
    private static func loginShell(script: String) -> String {
        let payload = "exec 1>&3 3>&-\n" + script
        return "exec /bin/bash -lc " + shellQuote(payload) + " 3>&1 1>&2"
    }
}
