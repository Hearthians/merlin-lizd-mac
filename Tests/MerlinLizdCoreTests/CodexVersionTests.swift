import Testing
@testable import MerlinLizdCodexAdapter

@Suite("Codex version and executable resolution", .serialized)
struct CodexVersionTests {
    @Test("parses only exact codex-cli semantic version output")
    func parsesExactVersionOutput() throws {
        #expect(
            try CodexVersion.parse(commandOutput: "codex-cli 0.144.2\n")
                == CodexVersion(major: 0, minor: 144, patch: 2)
        )
        #expect(
            try CodexVersion.parse(commandOutput: "codex-cli 0.144.2")
                == CodexVersion(major: 0, minor: 144, patch: 2)
        )
        #expect(
            try CodexVersion.parse(commandOutput: "codex-cli 0.144.2\r\n")
                == CodexVersion(major: 0, minor: 144, patch: 2)
        )
        #expect(throws: CodexVersionParseError.self) {
            try CodexVersion.parse(commandOutput: "codex 0.144.2\n")
        }
        #expect(throws: CodexVersionParseError.self) {
            try CodexVersion.parse(commandOutput: " codex-cli 0.144.2\n")
        }
        #expect(throws: CodexVersionParseError.self) {
            try CodexVersion.parse(commandOutput: "codex-cli 0.144.2-beta\n")
        }
        #expect(throws: CodexVersionParseError.self) {
            try CodexVersion.parse(commandOutput: "codex-cli 0.144.2 extra\n")
        }
        for malformed in [
            "codex-cli 00.144.2\n",
            "codex-cli 0.0144.2\n",
            "codex-cli 0.144.02\n",
            "codex-cli 0.144.2\r",
        ] {
            #expect(throws: CodexVersionParseError.self) {
                try CodexVersion.parse(commandOutput: malformed)
            }
        }
    }

    @Test("orders semantic versions and accepts only the reviewed range")
    func comparesSupportedRange() {
        let minimum = CodexVersion(major: 0, minor: 144, patch: 2)
        #expect(CodexVersion(major: 0, minor: 144, patch: 1) < minimum)
        #expect(CodexVersion(major: 0, minor: 144, patch: 9) > minimum)
        #expect(CodexVersion(major: 0, minor: 145, patch: 0) > minimum)
        #expect(!CodexVersion(major: 1, minor: 0, patch: 0).isSupported)
        #expect(!CodexVersion(major: 0, minor: 144, patch: 1).isSupported)
        #expect(minimum.isSupported)
        #expect(CodexVersion(major: 0, minor: 144, patch: 999).isSupported)
        #expect(!CodexVersion(major: 0, minor: 145, patch: 0).isSupported)
    }

    @Test("resolver candidates have fixed precedence and are deduplicated")
    func resolvesCandidatesInOrder() {
        let resolver = CodexExecutableResolver(
            override: testURL("/test/override"),
            environment: ["PATH": "/path/a:/opt/homebrew/bin::/path/b:/path/a"],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: []),
            versionProbe: ScriptedCodexVersionProbe()
        )

        #expect(resolver.candidatePathsForTesting == [
            "/test/override",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/path/a/codex",
            "/opt/homebrew/bin/codex",
            "/path/b/codex",
            "/Users/test/.local/bin/codex",
            "/usr/local/bin/codex",
        ])
    }

    @Test("resolver probes only the first executable candidate")
    func probesFirstExecutable() async throws {
        let checker = ScriptedCodexFileChecker(executablePaths: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/path/codex",
        ])
        let probe = ScriptedCodexVersionProbe(
            output: "codex-cli 0.144.2\n"
        )
        let resolver = CodexExecutableResolver(
            environment: ["PATH": "/path"],
            homeDirectory: testURL("/Users/test"),
            fileChecker: checker,
            versionProbe: probe
        )

        let resolved = try await resolver.resolve()

        #expect(
            resolved.executable.path
                == "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
        #expect(
            resolved.version
                == CodexVersion(major: 0, minor: 144, patch: 2)
        )
        #expect(await probe.probedPaths() == [
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ])
    }

    @Test("foundation executable check resolves symlinks and rejects special files")
    func executableCheckRequiresAFile() throws {
        let result = try exerciseFoundationExecutableChecker()
        #expect(!result.directoryAccepted)
        #expect(result.fileAccepted)
        #expect(!result.fifoAccepted)
        #expect(!result.socketAccepted)
        #expect(!result.deviceAccepted)
        #expect(result.symlinkAccepted)
        #expect(result.resolvedSymlinkPath == result.filePath)
    }

    @Test("resolver reports a typed error when no candidate is executable")
    func reportsMissingExecutable() async {
        let resolver = CodexExecutableResolver(
            environment: ["PATH": "/missing"],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: []),
            versionProbe: ScriptedCodexVersionProbe()
        )

        await #expect(throws: CodexExecutableResolverError.notFound) {
            try await resolver.resolve()
        }
    }

    @Test("resolver rejects an unsupported first executable without fallback")
    func rejectsUnsupportedVersion() async {
        let probe = ScriptedCodexVersionProbe(
            output: "codex-cli 0.145.0\n"
        )
        let resolver = CodexExecutableResolver(
            environment: ["PATH": "/newer:/supported"],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: [
                "/newer/codex", "/supported/codex",
            ]),
            versionProbe: probe
        )

        await #expect(throws: CodexExecutableResolverError.self) {
            try await resolver.resolve()
        }
        #expect(await probe.probedPaths() == ["/newer/codex"])
    }

    @Test("version probing uses a two-second default absolute deadline")
    func usesDefaultProbeDeadline() async throws {
        let probe = ScriptedCodexVersionProbe(
            output: "codex-cli 0.144.2\n"
        )
        let resolver = CodexExecutableResolver(
            override: testURL("/codex"),
            environment: [:],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: ["/codex"]),
            versionProbe: probe
        )

        _ = try await resolver.resolve()

        #expect(CodexExecutableResolver.defaultProbeTimeout == .seconds(2))
        let remaining = try #require(await probe.recordedRemainingDurations().first)
        #expect(remaining > .seconds(1))
        #expect(remaining <= .seconds(2))
    }

    @Test("version probe timeout cancels the probe and returns a typed error")
    func timesOutProbe() async {
        let probe = ScriptedCodexVersionProbe(suspendUntilCancelled: true)
        let resolver = CodexExecutableResolver(
            override: testURL("/codex"),
            environment: [:],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: ["/codex"]),
            versionProbe: probe,
            probeTimeout: .milliseconds(10)
        )

        await #expect(throws: CodexExecutableResolverError.self) {
            try await resolver.resolve()
        }
        let cancellationDeadline = ContinuousClock.now.advanced(
            by: .milliseconds(100)
        )
        while await !probe.wasCancelled(),
            ContinuousClock.now < cancellationDeadline
        {
            await Task.yield()
        }
        #expect(await probe.wasCancelled())
    }

    @Test("version probe deadline returns even when the probe ignores cancellation")
    func timeoutDoesNotAwaitCancellationIgnoringProbe() async {
        let probe = ScriptedCodexVersionProbe(
            ignoreCancellationFor: .milliseconds(500)
        )
        let resolver = CodexExecutableResolver(
            override: testURL("/codex"),
            environment: [:],
            homeDirectory: testURL("/Users/test"),
            fileChecker: ScriptedCodexFileChecker(executablePaths: ["/codex"]),
            versionProbe: probe,
            probeTimeout: .milliseconds(10)
        )
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: CodexExecutableResolverError.probeTimedOut) {
            try await resolver.resolve()
        }
        #expect(started.duration(to: clock.now) < .milliseconds(200))
    }
}
