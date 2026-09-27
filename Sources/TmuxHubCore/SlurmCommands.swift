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
            exec tmux new-session -d -s \(shellQuote(receipt.tmuxSessionName)) /bin/sh -c \(shellQuote(srunScript))
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
                "exec /bin/sh -c " + shellQuote(script),
            ]
        )
    }
}
