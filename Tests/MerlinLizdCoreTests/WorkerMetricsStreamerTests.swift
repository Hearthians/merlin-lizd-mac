import Darwin
import Testing
@testable import MerlinLizdCore

@Suite("Worker metrics streaming", .serialized)
struct WorkerMetricsStreamerTests {
    @Test("frames every complete envelope across arbitrary byte chunks")
    func framesChunkedEnvelopes() throws {
        let wireOutput = [
            "SSH transport banner\r\n",
            "__MERLIN_LIZD_METRICS_V1_BEGIN__\r\n",
            "__MERLIN_LIZD_METRICS_MEMORY__\r\n",
            "MemTotal: 100 kB\r\n",
            "MemAvailable: 25 kB\r\n",
            "__MERLIN_LIZD_METRICS_V1_END__\r\n",
            "unrelated output\r\n",
            "__MERLIN_LIZD_METRICS_V1_BEGIN__\r\n",
            "__MERLIN_LIZD_METRICS_MEMORY__\r\n",
            "MemTotal: 200 kB\r\n",
            "MemAvailable: 50 kB\r\n",
            "__MERLIN_LIZD_METRICS_V1_END__\r\n",
        ].joined()
        let bytes = Array(wireOutput.utf8)
        let chunkSizes = [1, 2, 7, 3, 19, 5, 11]
        var offset = 0
        var chunkIndex = 0
        var framer = WorkerMetricsEnvelopeFramer()
        var envelopes: [String] = []

        while offset < bytes.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], bytes.count - offset)
            envelopes += try framer.append(Array(bytes[offset..<(offset + size)]))
            offset += size
            chunkIndex += 1
        }
        envelopes += try framer.finish()

        #expect(envelopes.count == 2)
        let samples = try envelopes.map { try WorkerMetricsParser.parse($0) }
        #expect(samples.map(\.memoryTotalBytes) == [102_400, 204_800])
        #expect(!framer.hasIncompleteEnvelope)
    }

    @Test("ignores bounded oversized transport noise outside an envelope")
    func ignoresOversizedNoiseLine() throws {
        var framer = WorkerMetricsEnvelopeFramer(
            maximumLineBytes: 64,
            maximumEnvelopeBytes: 256
        )
        #expect(try framer.append([UInt8](repeating: 0x78, count: 1_024)).isEmpty)
        let envelope = """
            ignored tail
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 10 kB
            __MERLIN_LIZD_METRICS_V1_END__
            """
        var framed = try framer.append(Array(("\n" + envelope).utf8))
        framed += try framer.finish()
        #expect(framed.count == 1)
    }

    @Test("continuously drains stderr while retaining only its bounded tail")
    func drainsBoundedStderr() async {
        let runner = POSIXInventoryProcessStreamer(stderrTailByteLimit: 1_024)
        let output = runner.streamStandardOutput(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "i=0; while [ $i -lt 6000 ]; do printf 0123456789abcdef0123456789abcdef >&2; i=$((i + 1)); done; printf '__TAIL__\\n' >&2; exit 7",
            ]
        ))

        do {
            for try await _ in output.chunks {}
            await output.waitForTermination()
            Issue.record("Expected the command to fail")
        } catch let InventoryProcessStreamError.commandFailed(exitCode, stderrTail) {
            #expect(exitCode == 7)
            #expect(stderrTail.utf8.count <= 1_024)
            #expect(stderrTail.hasSuffix("__TAIL__\n"))
        } catch {
            Issue.record("Unexpected stream error: \(error)")
        }
    }

    @Test("stdout flood without a consumer overflows the bounded buffer and reaps")
    func stdoutFloodFailsClosed() async throws {
        let pidFile = TemporaryProcessIDFile()

        let runner = POSIXInventoryProcessStreamer(
            maximumBufferedStdoutBytes: 16 * 1_024
        )
        let output = runner.streamStandardOutput(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; exec /usr/bin/yes merlin-lizd-stdout-flood",
                "merlin-lizd-stdout-flood-test",
                pidFile.path,
            ]
        ))
        var processID: pid_t?

        try await withAsyncCleanup({
            processID = try await pidFile.waitForProcessID()
            let child = try #require(processID)

            // Deliberately do not create an iterator until the producer has
            // detected overflow, terminated the process group, and reaped it.
            await output.waitForTermination()
            #expect(pidFile.processIsAbsent(child))

            do {
                for try await _ in output.chunks {}
                Issue.record("Expected a bounded stdout overflow")
            } catch InventoryProcessStreamError.stdoutBufferOverflow(
                let maxBufferedBytes
            ) {
                #expect(maxBufferedBytes == 16 * 1_024)
            } catch {
                Issue.record("Unexpected stream error: \(error)")
            }
        }, cleanup: {
            if let processID {
                _ = kill(processID, SIGKILL)
            }
            await output.cancelAndWait()
            pidFile.remove()
        })
    }

    @Test("stream completion wins a later cancellation without signaling descendants")
    func finalizedStreamIgnoresLateCancellation() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()
        let descendantProbeFile = TemporaryProcessIDFile()
        let descendantProbeFIFO = TemporaryMarkerFile()
        let completionGate = AsyncStartGate()
        let (cancellationDecisions, cancellationDecisionContinuation) =
            AsyncStream<Bool>.makeStream()
        var cancellationDecisionIterator = cancellationDecisions.makeAsyncIterator()
        let runner = POSIXInventoryProcessStreamer(
            cancellationDecisionHook: { cancelled in
                cancellationDecisionContinuation.yield(cancelled)
            },
            completionBoundaryHook: {
                await completionGate.wait()
            }
        )
        let output = runner.streamStandardOutput(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; /bin/sh -c '/usr/bin/mkfifo \"$2\"; exec 3<> \"$2\"; trap \"echo \\$\\$ > \\\"$1\\\"\" USR1; exec 1>&- 2>&-; while :; do read value <&3; done' probe \"$3\" \"$4\" & echo $! > \"$2\"; exit 0",
                "merlin-lizd-stream-finalized-cancel-test",
                parentPIDFile.path,
                descendantPIDFile.path,
                descendantProbeFile.path,
                descendantProbeFIFO.path,
            ]
        ))
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?
        var cancellationTask: Task<Void, Never>?

        try await withAsyncCleanup({
            await completionGate.waitUntilEntered()
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            let descendant = try #require(descendantProcessID)
            #expect(parentPIDFile.processIsAbsent(parent))
            #expect(!descendantPIDFile.processIsAbsent(descendant))

            cancellationTask = Task {
                await output.cancelAndWait()
            }
            #expect(await cancellationDecisionIterator.next() == false)
            #expect(kill(descendant, SIGUSR1) == 0)
            #expect(try await descendantProbeFile.waitForProcessID() == descendant)
            await completionGate.open()
            await cancellationTask?.value

            do {
                for try await _ in output.chunks {}
            } catch {
                Issue.record("Expected finalized stream success, got \(error)")
            }
        }, cleanup: {
            cancellationTask?.cancel()
            await completionGate.open()
            if let parentProcessID {
                _ = kill(parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            await output.cancelAndWait()
            await cancellationTask?.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
            descendantProbeFile.remove()
            descendantProbeFIFO.remove()
        })
    }

    @Test("stream cancellation before atomic finalization kills before reap")
    func streamCancellationBeforeFinalizationKillsGroup() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()
        let decisionGate = AsyncStartGate()
        let runner = POSIXInventoryProcessStreamer(
            completionDecisionBoundaryHook: {
                await decisionGate.wait()
            }
        )
        let output = runner.streamStandardOutput(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; /bin/sh -c 'trap \"\" TERM; exec 1>&- 2>&-; exec /bin/sleep 30' & echo $! > \"$2\"; exit 0",
                "merlin-lizd-stream-decision-cancel-test",
                parentPIDFile.path,
                descendantPIDFile.path,
            ]
        ))
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?
        var cancellationTask: Task<Void, Never>?

        try await withAsyncCleanup({
            await decisionGate.waitUntilEntered()
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            let descendant = try #require(descendantProcessID)
            #expect(parentPIDFile.processHasExitedWithoutReaping(parent))
            #expect(getpgid(descendant) == parent)

            cancellationTask = Task { await output.cancelAndWait() }
            var descendantWasKilledBeforeReap = false
            for _ in 0..<100 {
                if descendantPIDFile.processIsAbsent(descendant) {
                    descendantWasKilledBeforeReap = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await decisionGate.open()
            await cancellationTask?.value

            #expect(descendantWasKilledBeforeReap)
            #expect(parentPIDFile.processIsAbsent(parent))
            #expect(descendantPIDFile.processIsAbsent(descendant))
        }, cleanup: {
            cancellationTask?.cancel()
            await decisionGate.open()
            if let parentProcessID {
                _ = kill(-parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            await output.cancelAndWait()
            await cancellationTask?.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
        })
    }

    @Test("streamer yields each framed sample from one process stream")
    func streamerYieldsEverySample() async throws {
        let wireOutput = """
            transport banner
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 100 kB
            MemAvailable: 25 kB
            __MERLIN_LIZD_METRICS_V1_END__
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 200 kB
            MemAvailable: 50 kB
            __MERLIN_LIZD_METRICS_V1_END__
            """
        let bytes = Array((wireOutput + "\n").utf8)
        let midpoint = bytes.count / 2
        let processStreamer = ChunkedInventoryProcessStreamer(chunks: [
            Array(bytes[..<midpoint]),
            Array(bytes[midpoint...]),
        ])
        let directory = temporarySSHDirectory()
        let poolRunner = SSHMasterScriptedRunner(actions: [.exit(255), .succeed])
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let streamer = WorkerMetricsStreamer(
            sshMasterPool: pool,
            processStreamer: processStreamer
        )
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )
        var iterator = streamer.stream(
            target: target,
            intervalSeconds: 3
        ).makeAsyncIterator()

        let first = try await iterator.next()
        let second = try await iterator.next()
        #expect(first?.memoryTotalBytes == 102_400)
        #expect(second?.memoryTotalBytes == 204_800)
        let command = try #require(processStreamer.recordedCommand())
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(command.arguments.contains("ControlPath=\(expectedPath)"))
        do {
            _ = try await iterator.next()
            Issue.record("Expected an ended persistent connection")
        } catch WorkerMetricsStreamingError.connectionEnded {
            // Expected: the injected finite stream ended after two envelopes.
        } catch {
            Issue.record("Unexpected stream error: \(error)")
        }
    }

    @Test("cancelling iteration kills and reaps the whole process group")
    func cancellationReapsProcessGroup() async throws {
        let parentPIDFile = TemporaryProcessIDFile()
        let descendantPIDFile = TemporaryProcessIDFile()
        var parentProcessID: pid_t?
        var descendantProcessID: pid_t?
        let runner = POSIXInventoryProcessStreamer()
        let output = runner.streamStandardOutput(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; /bin/sh -c 'trap \"\" TERM; exec /bin/sleep 30' & echo $! > \"$2\"; trap '' TERM; wait",
                "merlin-lizd-stream-cancel-test",
                parentPIDFile.path,
                descendantPIDFile.path,
            ]
        ))
        let consumer = Task {
            for try await _ in output.chunks {}
        }

        try await withAsyncCleanup({
            parentProcessID = try await parentPIDFile.waitForProcessID()
            descendantProcessID = try await descendantPIDFile.waitForProcessID()
            let parent = try #require(parentProcessID)
            #expect(getpgid(parent) == parent)
            if let descendantProcessID {
                #expect(getpgid(descendantProcessID) == parent)
            }

            consumer.cancel()
            _ = try? await consumer.value
            await output.cancelAndWait()

            #expect(await waitUntilAbsent(parent))
            if let descendantProcessID {
                #expect(await waitUntilAbsent(descendantProcessID))
            }
        }, cleanup: {
            consumer.cancel()
            if let parentProcessID {
                _ = kill(-parentProcessID, SIGKILL)
            }
            if let descendantProcessID {
                _ = kill(descendantProcessID, SIGKILL)
            }
            await output.cancelAndWait()
            _ = try? await consumer.value
            parentPIDFile.remove()
            descendantPIDFile.remove()
        })
    }

    @Test("shutdown cancels lease waiters and permanently rejects late producers")
    func shutdownClosesOuterProducerGate() async {
        WorkerMetricsStreamer.resetShutdownStateForTesting()

        let processStreamer = BlockingInventoryProcessStreamer()
        let streamer = WorkerMetricsStreamer(processStreamer: processStreamer)
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )
        let firstStream = streamer.stream(target: target)
        let secondStream = streamer.stream(target: target)
        let firstConsumer = Task { await consumeUntilFinished(firstStream) }
        let secondConsumer = Task { await consumeUntilFinished(secondStream) }

        #expect(await processStreamer.waitUntilLaunchCount(1))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(processStreamer.launches() == 1)

        await WorkerMetricsStreamer.shutdownAll()

        #expect(await firstConsumer.value)
        #expect(await secondConsumer.value)
        #expect(processStreamer.launches() == 1)

        let rejectedStream = streamer.stream(target: target)
        do {
            for try await _ in rejectedStream {}
            Issue.record("Expected shutdown to reject a late producer")
        } catch WorkerMetricsStreamingError.shutDown {
            // Expected: the production shutdown gate is permanent.
        } catch {
            Issue.record("Unexpected late-producer error: \(error)")
        }
        #expect(processStreamer.launches() == 1)

        WorkerMetricsStreamer.resetShutdownStateForTesting()
    }

    @Test("global shutdown cancels and reaps every active streaming process")
    func globalShutdownReapsAllStreams() async throws {
        WorkerMetricsStreamer.resetShutdownStateForTesting()
        let firstPIDFile = TemporaryProcessIDFile()
        let secondPIDFile = TemporaryProcessIDFile()
        let runner = POSIXInventoryProcessStreamer()
        let first = runner.streamStandardOutput(termResistantCommand(
            pidFile: firstPIDFile,
            label: "first"
        ))
        let second = runner.streamStandardOutput(termResistantCommand(
            pidFile: secondPIDFile,
            label: "second"
        ))
        var firstProcessID: pid_t?
        var secondProcessID: pid_t?

        try await withAsyncCleanup({
            firstProcessID = try await firstPIDFile.waitForProcessID()
            secondProcessID = try await secondPIDFile.waitForProcessID()
            let firstChild = try #require(firstProcessID)
            let secondChild = try #require(secondProcessID)

            await WorkerMetricsStreamer.shutdownAll()
            WorkerMetricsStreamer.resetShutdownStateForTesting()
            await first.waitForTermination()
            await second.waitForTermination()

            #expect(firstPIDFile.processIsAbsent(firstChild))
            #expect(secondPIDFile.processIsAbsent(secondChild))
        }, cleanup: {
            if let firstProcessID {
                _ = kill(firstProcessID, SIGKILL)
            }
            if let secondProcessID {
                _ = kill(secondProcessID, SIGKILL)
            }
            await first.cancelAndWait()
            await second.cancelAndWait()
            WorkerMetricsStreamer.resetShutdownStateForTesting()
            firstPIDFile.remove()
            secondPIDFile.remove()
        })
    }

    private func termResistantCommand(
        pidFile: TemporaryProcessIDFile,
        label: String
    ) -> CommandSpec {
        CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; trap '' TERM; exec /bin/sleep 30",
                "merlin-lizd-shutdown-\(label)-test",
                pidFile.path,
            ]
        )
    }

    private func consumeUntilFinished(
        _ stream: AsyncThrowingStream<WorkerMetricsSample, Error>
    ) async -> Bool {
        do {
            for try await _ in stream {}
            return true
        } catch {
            return true
        }
    }

    private func waitUntilAbsent(_ processID: pid_t) async -> Bool {
        for _ in 0..<700 {
            errno = 0
            if kill(processID, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        errno = 0
        return kill(processID, 0) == -1 && errno == ESRCH
    }
}
