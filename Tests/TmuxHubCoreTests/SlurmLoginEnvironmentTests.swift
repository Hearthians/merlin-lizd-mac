import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm login environment")
struct SlurmLoginEnvironmentTests {
    private let platform = SlurmPlatformProfile(
        id: "hkust-hpc2", name: "HKUST HPC2", loginDestination: "hpc2", owner: "zli760"
    )

    @Test("queue commands load the login PATH without parsing profile banners as jobs")
    func queryUsesLoginProfile() async throws {
        let fixture = try SlurmLoginFixture()
        defer { fixture.remove() }
        let line = queueLine(jobID: "808_7", name: "research", comment: "")
        try fixture.write("queue-output", contents: line + "\n")

        let commands = [
            try SlurmCommands.listJobs(platform: platform),
            try SlurmCommands.inspectJob(
                platform: platform, jobID: #require(SlurmJobID(rawValue: "808_7"))
            ),
        ]
        for command in commands {
            let output = try await fixture.runRemote(command)
            #expect(output.exitCode == 0, "\(output.stderr)")
            #expect(output.stdout == line + "\n")
            #expect(output.stderr.contains("fixture login profile banner"))
            let jobs = try SlurmParser.queue(output.stdout)
            #expect(jobs.count == 1)
            #expect(jobs.first?.jobID.rawValue == "808_7")
            let arguments = try fixture.arguments("squeue-arguments")
            #expect(arguments.contains(SlurmCommands.queueFormat))
        }
    }

    @Test("a pane reloads the login PATH inherited by a stale tmux server and preserves literal arguments")
    func startWithStaleServerEnvironment() async throws {
        let fixture = try SlurmLoginFixture()
        defer { fixture.remove() }
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        let workingDirectory = "/workspace/space ' $HOME $(printf expanded) `printf expanded` 中文"
        let initialization = "printf '%s\\n' \"literal ' quote and $HOME\"\nexport LABEL='research run'"
        let preset = SlurmInteractivePreset(
            id: "research", name: "Research", partition: "debug", cpusPerTask: 4,
            memoryMiB: 16_384, wallTime: SlurmWallTime(seconds: 1_800),
            gpu: SlurmGPURequest(type: "a40", count: 1),
            workingDirectory: workingDirectory, initializationScript: initialization
        )

        let command = try SlurmCommands.startInteractive(
            platform: platform, preset: preset, receipt: receipt
        )
        let output = try await fixture.runRemote(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        #expect(try fixture.arguments("tmux-pane-arguments").prefix(2) == ["/bin/bash", "-lc"])
        #expect(try fixture.arguments("srun-arguments") == [
            "--job-name", receipt.jobName,
            "--comment", receipt.comment,
            "--partition", "debug",
            "--ntasks", "1",
            "--cpus-per-task", "4",
            "--mem", "16384M",
            "--time", "00:30:00",
            "--gres", "gpu:a40:1",
            "--chdir", workingDirectory,
            "--pty", "/bin/bash", "-lc", initialization + "\nexec /bin/bash -l",
        ])
    }

    @Test("the login-shell cancellation guard preserves exact identity and fails closed on changed rows")
    func cancellationGuardExecutesAfterLogin() async throws {
        let fixture = try SlurmLoginFixture()
        defer { fixture.remove() }
        let receipt = try SlurmCommands.launchReceipt(platform: platform)
        let jobID = "808_7"
        let snapshot = try #require(SlurmParser.queue(queueLine(
            jobID: jobID, name: receipt.jobName, comment: receipt.comment
        )).first)
        let command = try SlurmCommands.cancelVerified(
            platform: platform, managedJob: SlurmManagedJob(receipt: receipt, snapshot: snapshot)
        )
        let identity = "\(jobID) \(receipt.owner) \(receipt.jobName) \(receipt.comment)"
        let mismatches = [
            "808_8 \(receipt.owner) \(receipt.jobName) \(receipt.comment)",
            "\(jobID) another-user \(receipt.jobName) \(receipt.comment)",
            "\(jobID) \(receipt.owner) another-job \(receipt.comment)",
            "\(jobID) \(receipt.owner) \(receipt.jobName) tmuxhub:another-request",
            identity + "\n" + identity,
            "",
        ]
        for row in mismatches {
            try fixture.write("queue-output", contents: row + "\n")
            let output = try await fixture.runRemote(command)
            #expect(output.exitCode == 74, "\(output.stderr)")
            #expect(output.stdout.isEmpty)
            #expect(!fixture.exists("scancel-arguments"))
        }

        // squeue's display padding must not invalidate an otherwise exact identity.
        try fixture.write("queue-output", contents: "  \(identity)   \n")
        let output = try await fixture.runRemote(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.contains("fixture login profile banner"))
        #expect(try fixture.arguments("squeue-arguments") == [
            "--noheader", "--jobs", jobID, "--format", "%i %u %j %k",
        ])
        #expect(try fixture.arguments("scancel-arguments") == [jobID])
    }

    private func queueLine(jobID: String, name: String, comment: String) -> String {
        [jobID, name, platform.owner, "RUNNING", "gpu02", "debug", "1", "00:01",
         "00:30:00", "2026-09-28T10:00:00", "2026-09-28T09:59:00", "gpu02", comment]
            .joined(separator: "\u{001F}")
    }
}

private struct SlurmLoginFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tmuxhub-slurm-login-\(UUID().uuidString) space ' $() 中文", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        try write(".bash_profile", contents: """
            export PATH="$TMUXHUB_FIXTURE_ROOT/bin:/usr/bin:/bin"
            printf '%s\\n' 'fixture login profile banner'
            """)
        try executable("squeue", script: """
            printf '%s\\0' "$@" > "$TMUXHUB_FIXTURE_ROOT/squeue-arguments"
            exec /bin/cat "$TMUXHUB_FIXTURE_ROOT/queue-output"
            """)
        try executable("srun", script: """
            printf '%s\\0' "$@" > "$TMUXHUB_FIXTURE_ROOT/srun-arguments"
            """)
        try executable("scancel", script: """
            printf '%s\\0' "$@" > "$TMUXHUB_FIXTURE_ROOT/scancel-arguments"
            """)
        try executable("tmux", script: """
            case "$1" in
                has-session) exit 1 ;;
                new-session)
                    [ "$2" = -d ] && [ "$3" = -s ] || exit 92
                    shift 4
                    printf '%s\\0' "$@" > "$TMUXHUB_FIXTURE_ROOT/tmux-pane-arguments"
                    # Model an existing server with a PATH that predates the Slurm setup.
                    exec /usr/bin/env -i HOME="$HOME" TMUXHUB_FIXTURE_ROOT="$TMUXHUB_FIXTURE_ROOT" PATH=/usr/bin:/bin "$@"
                    ;;
                *) exit 93 ;;
            esac
            """)
    }

    func runRemote(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let script = try #require(command.arguments.last)
        return try await TimedInventoryProcessRunner(
            timeout: .seconds(5), underlying: FoundationInventoryProcessRunner()
        ).run(CommandSpec(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: [
                "HOME": directory.path,
                "PATH": "/usr/bin:/bin",
                "BASH_ENV": "/dev/null",
                "ENV": "/dev/null",
                "TMUXHUB_FIXTURE_ROOT": directory.path,
            ]
        ))
    }

    func write(_ name: String, contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func arguments(_ name: String) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func executable(_ name: String, script: String) throws {
        try write("bin/" + name, contents: "#!/bin/sh\n" + script + "\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("bin/" + name).path
        )
    }
}
