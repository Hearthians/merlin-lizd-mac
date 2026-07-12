import Foundation

public struct CommandSpec: Equatable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum CommandValidationError: Error, Equatable, Sendable {
    case invalidAlias
    case invalidWorkerID
    case invalidSessionName
    case invalidExecutablePath
    case invalidSID
    case workerTargetRequired
    case invalidMetricsInterval
    case invalidWorkerPageSize
}

public enum MerlinCommands {
    public static func sshAlias(for target: TerminalTarget) -> String? {
        switch target {
        case .local:
            nil
        case let .devbox(_, _, alias), let .worker(_, _, alias, _):
            alias
        }
    }

    /// Captures one machine-readable, read-only metrics snapshot inside a
    /// Worker. Shell separators are escaped at the Devbox hop so `mlx` receives
    /// them as arguments and reconstructs them only inside the Worker shell.
    /// No Worker network coordinates or SSH configuration are embedded here.
    public static func sampleWorkerMetrics(
        target: TerminalTarget
    ) throws -> CommandSpec {
        let (alias, workerID) = try validatedWorkerRoute(target)
        let separator = #"\;"#
        let commands = [
            "export LC_ALL=C",
            workerMetricsSnapshotCommands(separator: separator),
        ].joined(separator: " \(separator) ")

        return workerCommand(
            alias: alias,
            workerID: workerID,
            remoteCommands: commands
        )
    }

    /// Builds one persistent Worker-side loop. Each iteration emits a complete
    /// independently parseable envelope. The fixed integer interval is the
    /// only varying shell token and is range-checked before interpolation.
    public static func streamWorkerMetrics(
        target: TerminalTarget,
        intervalSeconds: Int
    ) throws -> CommandSpec {
        guard (1 ... 3_600).contains(intervalSeconds) else {
            throw CommandValidationError.invalidMetricsInterval
        }
        let (alias, workerID) = try validatedWorkerRoute(target)
        let separator = #"\;"#
        let snapshot = workerMetricsSnapshotCommands(separator: separator)
        let commands = [
            "export LC_ALL=C",
            "while true",
            "do \(snapshot) \(separator) sleep \(intervalSeconds)",
            "done",
        ].joined(separator: " \(separator) ")

        return streamingWorkerCommand(
            alias: alias,
            workerID: workerID,
            remoteCommands: commands
        )
    }

    public static func terminateTmuxSession(
        target: TerminalTarget,
        sessionName: String,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        try validateSessionName(sessionName)

        let tmuxArguments = ["kill-session", "-t", sessionName]
        switch target {
        case .local:
            guard localTmuxPath.hasPrefix("/") else {
                throw CommandValidationError.invalidExecutablePath
            }
            return CommandSpec(
                executable: localTmuxPath,
                arguments: tmuxArguments
            )
        case let .devbox(_, _, alias):
            try validateAlias(alias)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "tmux kill-session -t \(sessionName)"
                )
            )
        case let .worker(_, _, alias, workerID):
            try validateAlias(alias)
            try validateWorkerID(workerID)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- tmux kill-session -t \(sessionName)"
                )
            )
        }
    }

    public static func renameTmuxSession(
        target: TerminalTarget,
        from currentName: String,
        to newName: String,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        try validateSessionName(currentName)
        try validateSessionName(newName)

        let tmuxArguments = [
            "rename-session", "-t", currentName, newName,
        ]
        switch target {
        case .local:
            guard localTmuxPath.hasPrefix("/") else {
                throw CommandValidationError.invalidExecutablePath
            }
            return CommandSpec(
                executable: localTmuxPath,
                arguments: tmuxArguments
            )
        case let .devbox(_, _, alias):
            try validateAlias(alias)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "tmux rename-session -t \(currentName) \(newName)"
                )
            )
        case let .worker(_, _, alias, workerID):
            try validateAlias(alias)
            try validateWorkerID(workerID)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- tmux rename-session -t \(currentName) \(newName)"
                )
            )
        }
    }

    public static func listTmuxSessions(
        target: TerminalTarget,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        let tmuxArguments = ["list-sessions", "-F", "#{session_name}"]
        switch target {
        case .local:
            guard localTmuxPath.hasPrefix("/") else {
                throw CommandValidationError.invalidExecutablePath
            }
            return CommandSpec(executable: localTmuxPath, arguments: tmuxArguments)
        case let .devbox(_, _, alias):
            try validateAlias(alias)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "tmux list-sessions -F#{session_name}"
                )
            )
        case let .worker(_, _, alias, workerID):
            try validateAlias(alias)
            try validateWorkerID(workerID)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    // mlx reconstructs its remote command without preserving
                    // quoting. Keeping the format attached to -F prevents the
                    // leading # from becoming a shell comment.
                    remoteCommand: "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- tmux list-sessions -F#{session_name}"
                )
            )
        }
    }

    public static func warmWorker(target: TerminalTarget) throws -> CommandSpec {
        let (alias, workerID) = try validatedWorkerRoute(target)
        return workerCommand(
            alias: alias,
            workerID: workerID,
            // The Devbox shell removes the outer double quotes, leaving the
            // literal single quotes in mlx's argv. When mlx rejoins argv for
            // the Worker shell, those quotes still bind the entire fixed body
            // as sh -lc's one command-string argument.
            remoteCommands: #"sh -lc "'printf \"__MLZ_READY__\n\"; tmux list-sessions -F#{session_name}'""#
        )
    }

    public static func startDevbox(
        merlinCLIPath: String,
        sid: String
    ) throws -> CommandSpec {
        guard
            merlinCLIPath.hasPrefix("/"),
            !merlinCLIPath.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            throw CommandValidationError.invalidExecutablePath
        }
        guard MerlinIdentifierValidator.isDevboxSID(sid) else {
            throw CommandValidationError.invalidSID
        }

        let payloadData = try JSONEncoder().encode(StartPayload(sid: sid))
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw CommandValidationError.invalidSID
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "cpu-devbox", "instances", "start",
                "--control-plane", "cn",
                "--json", payload,
            ]
        )
    }

    public static func listWorkers(
        merlinCLIPath: String,
        instanceSID: String,
        pageSize: Int = 100,
        pageToken: String? = nil
    ) throws -> CommandSpec {
        guard
            merlinCLIPath.hasPrefix("/"),
            !merlinCLIPath.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            throw CommandValidationError.invalidExecutablePath
        }
        guard MerlinIdentifierValidator.isDevboxSID(instanceSID) else {
            throw CommandValidationError.invalidSID
        }
        guard (1 ... 100).contains(pageSize) else {
            throw CommandValidationError.invalidWorkerPageSize
        }

        let request = WorkerListPayload(
            filter: .init(instanceSID: instanceSID),
            pageSize: pageSize,
            pageToken: pageToken
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(request)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw CommandValidationError.invalidSID
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "cpu-devbox", "workers", "list",
                "--control-plane", "cn",
                "--json", payload,
            ]
        )
    }

    public static func devboxTerminal(
        alias: String,
        sessionName: String
    ) throws -> CommandSpec {
        try validateAlias(alias)
        try validateSessionName(sessionName)

        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: interactiveSSHArguments(
                alias: alias,
                remoteCommand: "exec tmux new-session -A -s \(sessionName)"
            )
        )
    }

    public static func workerTerminal(
        alias: String,
        workerID: String,
        sessionName: String
    ) throws -> CommandSpec {
        try validateAlias(alias)
        try validateWorkerID(workerID)
        try validateSessionName(sessionName)

        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: interactiveSSHArguments(
                alias: alias,
                remoteCommand: "exec mlx worker login \(workerID) -- tmux new-session -A -s \(sessionName)"
            )
        )
    }

    private static func interactiveSSHArguments(
        alias: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            alias,
            remoteCommand,
        ]
    }

    private static func nonInteractiveSSHArguments(
        alias: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            alias,
            remoteCommand,
        ]
    }

    private static func validatedWorkerRoute(
        _ target: TerminalTarget
    ) throws -> (alias: String, workerID: String) {
        guard case let .worker(_, _, alias, workerID) = target else {
            throw CommandValidationError.workerTargetRequired
        }
        try validateAlias(alias)
        try validateWorkerID(workerID)
        return (alias, workerID)
    }

    private static func workerCommand(
        alias: String,
        workerID: String,
        remoteCommands: String
    ) -> CommandSpec {
        CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: nonInteractiveSSHArguments(
                alias: alias,
                remoteCommand: "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- \(remoteCommands)"
            )
        )
    }

    private static func streamingWorkerCommand(
        alias: String,
        workerID: String,
        remoteCommands: String
    ) -> CommandSpec {
        CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-nT",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3",
                alias,
                "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- \(remoteCommands)",
            ]
        )
    }

    private static func workerMetricsSnapshotCommands(
        separator: String
    ) -> String {
        func readableFile(_ path: String) -> String {
            "if test -r \(path) \(separator) then cat \(path) \(separator) fi"
        }

        return [
            "echo \(WorkerMetricsWireFormat.beginMarker)",
            "echo \(WorkerMetricsWireFormat.uptimeBeforeMarker)",
            "cat /proc/uptime",
            "echo \(WorkerMetricsWireFormat.cgroupV1CPUBeforeMarker)",
            readableFile("/sys/fs/cgroup/cpu,cpuacct/cpuacct.usage"),
            "echo \(WorkerMetricsWireFormat.cgroupV2CPUBeforeMarker)",
            readableFile("/sys/fs/cgroup/cpu.stat"),
            "echo \(WorkerMetricsWireFormat.cpuBeforeMarker)",
            "head -n 1 /proc/stat",
            "sleep 0.2",
            "echo \(WorkerMetricsWireFormat.uptimeAfterMarker)",
            "cat /proc/uptime",
            "echo \(WorkerMetricsWireFormat.cgroupV1CPUAfterMarker)",
            readableFile("/sys/fs/cgroup/cpu,cpuacct/cpuacct.usage"),
            "echo \(WorkerMetricsWireFormat.cgroupV2CPUAfterMarker)",
            readableFile("/sys/fs/cgroup/cpu.stat"),
            "echo \(WorkerMetricsWireFormat.cpuAfterMarker)",
            "head -n 1 /proc/stat",
            "echo \(WorkerMetricsWireFormat.cgroupV1CPUQuotaMarker)",
            readableFile("/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us"),
            "echo \(WorkerMetricsWireFormat.cgroupV1CPUPeriodMarker)",
            readableFile("/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_period_us"),
            "echo \(WorkerMetricsWireFormat.cgroupV2CPUMaxMarker)",
            readableFile("/sys/fs/cgroup/cpu.max"),
            "echo \(WorkerMetricsWireFormat.cgroupV1MemoryUsageMarker)",
            readableFile("/sys/fs/cgroup/memory/memory.usage_in_bytes"),
            "echo \(WorkerMetricsWireFormat.cgroupV1MemoryLimitMarker)",
            readableFile("/sys/fs/cgroup/memory/memory.limit_in_bytes"),
            "echo \(WorkerMetricsWireFormat.cgroupV2MemoryUsageMarker)",
            readableFile("/sys/fs/cgroup/memory.current"),
            "echo \(WorkerMetricsWireFormat.cgroupV2MemoryLimitMarker)",
            readableFile("/sys/fs/cgroup/memory.max"),
            "echo \(WorkerMetricsWireFormat.memoryMarker)",
            "cat /proc/meminfo",
            "echo \(WorkerMetricsWireFormat.gpuMarker)",
            "nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits",
            "echo \(WorkerMetricsWireFormat.endMarker)",
        ].joined(separator: " \(separator) ")
    }

    private static func validateAlias(_ value: String) throws {
        guard MerlinIdentifierValidator.isSSHAlias(value) else {
            throw CommandValidationError.invalidAlias
        }
    }

    private static func validateWorkerID(_ value: String) throws {
        guard MerlinIdentifierValidator.isWorkerID(value) else {
            throw CommandValidationError.invalidWorkerID
        }
    }

    private static func validateSessionName(_ value: String) throws {
        guard MerlinIdentifierValidator.isTmuxSessionName(value) else {
            throw CommandValidationError.invalidSessionName
        }
    }

    private struct StartPayload: Encodable {
        let sid: String
    }

    private struct WorkerListPayload: Encodable {
        struct Filter: Encodable {
            let instanceSID: String

            enum CodingKeys: String, CodingKey {
                case instanceSID = "instance_sid"
            }
        }

        let filter: Filter
        let pageSize: Int
        let pageToken: String?

        enum CodingKeys: String, CodingKey {
            case filter
            case pageSize = "page_size"
            case pageToken = "page_token"
        }
    }
}
