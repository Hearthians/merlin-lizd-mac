import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SSH local forwarding service")
struct SSHLocalForwardingServiceTests {
    @Test("uses the remote port locally and preserves the complete URL")
    func preferredPortAndURLRewrite() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([8765])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL(
            "http://localhost:8765/mesh%20viewer/?step=1250#result"
        ))

        let result = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: endpoint
        )

        #expect(result.absoluteString == "http://localhost:8765/mesh%20viewer/?step=1250#result")
        #expect(await transport.recordedOpenCalls() == [
            ForwardCall(
                alias: "cluster",
                localPort: 8765,
                remoteHost: "localhost",
                remotePort: 8765
            ),
        ])
        #expect(allocator.recordedPreferredPorts() == [8765])
    }

    @Test("retries with a new nonzero port after an OpenSSH bind collision")
    func retriesBindCollision() async throws {
        let transport = RecordingForwardingTransport(
            openSteps: [.portUnavailable, .succeed]
        )
        let allocator = ScriptedPortAllocator([8765, 49152])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://127.0.0.1:8765/"))

        let result = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: endpoint
        )

        #expect(result.absoluteString == "http://127.0.0.1:49152/")
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [8765, 49152])
        #expect(allocator.recordedPreferredPorts() == [8765, nil])
    }

    @Test("avoids browser-restricted ports for the local listener")
    func avoidsBrowserRestrictedPort() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([49_156])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:6000/"))

        let result = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: endpoint
        )

        #expect(result.port == 49_156)
        #expect(allocator.recordedPreferredPorts() == [nil])
        #expect(await transport.recordedOpenCalls().first?.remotePort == 6_000)
    }

    @Test("coalesces concurrent creation and reference-counts owners")
    func concurrentAcquireAndRelease() async throws {
        let transport = RecordingForwardingTransport(pausesFirstOpen: true)
        let allocator = ScriptedPortAllocator([6006])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:6006/tensorboard"))
        let firstOwner = UUID()
        let secondOwner = UUID()

        let first = Task {
            try await service.acquire(
                owner: firstOwner,
                destination: "cluster",
                endpoint: endpoint
            )
        }
        await transport.waitUntilOpenCallCount(1)
        let second = Task {
            try await service.acquire(
                owner: secondOwner,
                destination: "cluster",
                endpoint: endpoint
            )
        }
        await Task.yield()
        await transport.resumeFirstOpen()

        let firstURL = try await first.value
        let secondURL = try await second.value
        #expect(firstURL == secondURL)
        #expect(await transport.recordedOpenCalls().count == 1)

        await service.release(owner: firstOwner)
        #expect(await transport.recordedCancelCalls().isEmpty)
        await service.release(owner: secondOwner)
        let cancelCalls = await transport.recordedCancelCalls()
        let openCalls = await transport.recordedOpenCalls()
        #expect(cancelCalls == openCalls)
    }

    @Test("reuses a healthy cached route for a later URL on the same endpoint")
    func reusesHealthyRoute() async throws {
        let transport = RecordingForwardingTransport(masterRunning: true)
        let allocator = ScriptedPortAllocator([8080])
        let listener = ScriptedListenerProbe([true])
        let service = makeService(
            transport: transport,
            allocator: allocator,
            listenerProbe: listener
        )
        let firstEndpoint = try #require(LoopbackURL("http://localhost:8080/first"))
        let secondEndpoint = try #require(LoopbackURL("http://localhost:8080/second?q=1"))

        _ = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: firstEndpoint
        )
        let second = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: secondEndpoint
        )

        #expect(second.absoluteString == "http://localhost:8080/second?q=1")
        #expect(await transport.recordedOpenCalls().count == 1)
        #expect(await transport.recordedMasterChecks() == ["cluster"])
        #expect(listener.recordedPorts() == [8080])
    }

    @Test("repairs a cached route on the same port when its control master is gone")
    func replacesStaleRoute() async throws {
        let transport = RecordingForwardingTransport(masterRunning: false)
        let allocator = ScriptedPortAllocator([8080, 49153])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))

        _ = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: endpoint
        )
        let replacement = try await service.acquire(
            owner: UUID(),
            destination: "cluster",
            endpoint: endpoint
        )

        #expect(replacement.absoluteString == "http://localhost:8080/")
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [8080, 8080])
        #expect(allocator.recordedPreferredPorts() == [8080])
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [8080])
    }

    @Test("keeps identical remote ports on different SSH destinations isolated")
    func destinationIsPartOfRouteIdentity() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([8080, 49154])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))

        let first = try await service.acquire(
            owner: UUID(),
            destination: "cluster-a",
            endpoint: endpoint
        )
        let second = try await service.acquire(
            owner: UUID(),
            destination: "cluster-b",
            endpoint: endpoint
        )

        #expect(first.port == 8080)
        #expect(second.port == 49154)
        let calls = await transport.recordedOpenCalls()
        #expect(calls.map(\.alias) == ["cluster-a", "cluster-b"])
        #expect(calls.map(\.remotePort) == [8080, 8080])
    }

    @Test("keeps the original alias's pinned login nodes isolated through reuse and cleanup")
    func pinnedLoginNodesArePartOfRouteIdentity() async throws {
        let base = RecordingForwardingTransport()
        let firstNode = RecordingForwardingTransport()
        let secondNode = RecordingForwardingTransport()
        let firstEndpoint = CodexNotificationSSHEndpoint(destination: "hpc4",
            address: "10.120.81.43", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
        let secondEndpoint = CodexNotificationSSHEndpoint(destination: "hpc4",
            address: "10.120.81.41", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
        let transport = EndpointSelectingTransport(base: base,
            connections: [firstEndpoint: firstNode, secondEndpoint: secondNode])
        let service = SSHLocalForwardingService(transport: transport,
            portAllocator: ScriptedPortAllocator([8080, 49154, 49155]),
            listenerProbe: ScriptedListenerProbe([true]))
        let endpoint = try #require(LoopbackURL("http://localhost:8080/view"))
        let firstOwner = UUID()
        let first = try await service.acquire(owner: firstOwner, destination: "hpc4",
            endpoint: endpoint, sshEndpoint: firstEndpoint)
        let second = try await service.acquire(owner: UUID(), destination: "hpc4",
            endpoint: endpoint, sshEndpoint: secondEndpoint)
        let unpinned = try await service.acquire(owner: UUID(), destination: "hpc4", endpoint: endpoint)
        let reused = try await service.acquire(owner: firstOwner, destination: "hpc4",
            endpoint: endpoint, sshEndpoint: firstEndpoint)
        #expect(Set([first.port, second.port, unpinned.port]).count == 3)
        #expect(reused == first)
        #expect(await firstNode.recordedOpenCalls().count == 1)
        #expect(await secondNode.recordedOpenCalls().count == 1)
        #expect(await base.recordedOpenCalls().count == 1)
        #expect(await firstNode.recordedMasterChecks() == ["hpc4"])
        await service.release(owner: firstOwner)
        #expect(await firstNode.recordedCancelCalls().count == 1)
        #expect(await secondNode.recordedCancelCalls().isEmpty)
        #expect(await base.recordedCancelCalls().isEmpty)
        await service.shutdown()
        #expect(await secondNode.recordedCancelCalls().count == 1)
        #expect(await base.recordedCancelCalls().count == 1)
    }

    @Test("rejects a pinned endpoint belonging to a different SSH alias")
    func pinnedEndpointMustMatchDestination() async throws {
        let transport = RecordingForwardingTransport()
        let service = makeService(transport: transport, allocator: ScriptedPortAllocator([8080]))
        let pin = CodexNotificationSSHEndpoint(destination: "hpc4",
            address: "10.120.81.43", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
        await #expect(throws: SSHLocalForwardingError.self) {
            _ = try await service.acquire(owner: UUID(), destination: "another-host",
                endpoint: try #require(LoopbackURL("http://localhost:8080/")), sshEndpoint: pin)
        }
        #expect(await transport.recordedOpenCalls().isEmpty)
    }

    @Test("does not retry an unrelated SSH failure and exposes a localized error")
    func genericTransportFailure() async throws {
        let transport = RecordingForwardingTransport(openSteps: [.fail])
        let allocator = ScriptedPortAllocator([8080, 49155])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))

        await #expect(throws: SSHLocalForwardingError.unableToOpenForward) {
            _ = try await service.acquire(
                owner: UUID(),
                destination: "cluster",
                endpoint: endpoint
            )
        }

        #expect(await transport.recordedOpenCalls().count == 1)
        #expect(allocator.recordedPreferredPorts() == [8080])
        #expect(SSHLocalForwardingError.unableToOpenForward.localizedDescription.contains("SSH"))
    }

    @Test("closing the owner during creation cancels the completed forward")
    func closeDuringCreate() async throws {
        let transport = RecordingForwardingTransport(pausesFirstOpen: true)
        let allocator = ScriptedPortAllocator([3000])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:3000/"))
        let owner = UUID()

        let acquisition = Task {
            try await service.acquire(
                owner: owner,
                destination: "cluster",
                endpoint: endpoint
            )
        }
        await transport.waitUntilOpenCallCount(1)
        await service.release(owner: owner)
        await transport.resumeFirstOpen()

        switch await acquisition.result {
        case .success:
            Issue.record("Expected the released acquisition to be cancelled")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        let cancelCalls = await transport.recordedCancelCalls()
        let openCalls = await transport.recordedOpenCalls()
        #expect(cancelCalls == openCalls)
    }

    @Test("shutdown cancels active forwards and rejects later acquisition")
    func shutdownCleanup() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([9000])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("https://[::1]:9000/status"))

        _ = try await service.acquire(
            owner: UUID(),
            destination: "cluster-v6",
            endpoint: endpoint
        )
        await service.shutdown()
        await service.shutdown()

        #expect(await transport.recordedOpenCalls().first?.remoteHost == "::1")
        let cancelCalls = await transport.recordedCancelCalls()
        let openCalls = await transport.recordedOpenCalls()
        #expect(cancelCalls == openCalls)
        await #expect(throws: SSHLocalForwardingError.shuttingDown) {
            _ = try await service.acquire(
                owner: UUID(),
                destination: "cluster-v6",
                endpoint: endpoint
            )
        }
    }

    @Test("shutdown during creation waits for and cancels the exact forward")
    func shutdownDuringCreate() async throws {
        let transport = RecordingForwardingTransport(pausesFirstOpen: true)
        let allocator = ScriptedPortAllocator([7007])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:7007/"))

        let acquisition = Task {
            try await service.acquire(
                owner: UUID(),
                destination: "cluster",
                endpoint: endpoint
            )
        }
        await transport.waitUntilOpenCallCount(1)
        let shutdown = Task { await service.shutdown() }
        await Task.yield()
        await transport.resumeFirstOpen()
        await shutdown.value

        await #expect(throws: SSHLocalForwardingError.shuttingDown) {
            _ = try await acquisition.value
        }
        let cancelCalls = await transport.recordedCancelCalls()
        let openCalls = await transport.recordedOpenCalls()
        #expect(cancelCalls == openCalls)
    }

    @Test("shutdown waits for a final-owner cancellation already in flight")
    func shutdownWaitsForReleaseCleanup() async throws {
        let transport = RecordingForwardingTransport(pausesFirstCancel: true)
        let allocator = ScriptedPortAllocator([5050])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:5050/"))
        let owner = UUID()

        _ = try await service.acquire(
            owner: owner,
            destination: "cluster",
            endpoint: endpoint
        )
        let release = Task { await service.release(owner: owner) }
        await transport.waitUntilCancelCallCount(1)

        let shutdownFinished = CompletionFlag()
        let shutdown = Task {
            await service.shutdown()
            await shutdownFinished.mark()
        }
        while !(await service.isShuttingDownForTesting()) {
            await Task.yield()
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await shutdownFinished.value()))

        await transport.resumeFirstCancel()
        await release.value
        await shutdown.value
        #expect(await shutdownFinished.value())
    }

    @Test("reacquiring a route waits for its previous cancellation to finish")
    func reacquireWaitsForCancellation() async throws {
        let transport = RecordingForwardingTransport(pausesFirstCancel: true)
        let allocator = ScriptedPortAllocator([5051, 5051])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:5051/"))
        let firstOwner = UUID()
        let secondOwner = UUID()

        _ = try await service.acquire(
            owner: firstOwner,
            destination: "cluster",
            endpoint: endpoint
        )
        let release = Task { await service.release(owner: firstOwner) }
        await transport.waitUntilCancelCallCount(1)

        let reacquire = Task {
            try await service.acquire(
                owner: secondOwner,
                destination: "cluster",
                endpoint: endpoint
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await transport.recordedOpenCalls().count == 1)

        await transport.resumeFirstCancel()
        await release.value
        _ = try await reacquire.value

        #expect(await transport.recordedEvents() == [
            .open(5051),
            .cancelStarted(5051),
            .cancelFinished(5051),
            .open(5051),
        ])
        await service.release(owner: secondOwner)
    }

    @Test("saved links restore their remembered local port without allocating another")
    func restoresRememberedPort() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/view?q=1#mesh"))
        let owner = UUID()

        let result = try await service.acquire(
            owner: owner, destination: "cluster", endpoint: endpoint, localPort: 49170
        )

        #expect(result.absoluteString == "http://localhost:49170/view?q=1#mesh")
        #expect(allocator.recordedPreferredPorts().isEmpty)
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49170])
        await service.release(owner: owner)
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [49170])
    }

    @Test("remembered ports reject invalid and browser-restricted values")
    func rejectsInvalidRememberedPorts() async throws {
        let transport = RecordingForwardingTransport()
        let allocator = ScriptedPortAllocator([])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        for port in [-1, 0, 65_536, 6000] {
            await #expect(throws: SSHLocalForwardingError.invalidLocalPort(port)) {
                try await service.acquire(
                    owner: UUID(), destination: "cluster", endpoint: endpoint, localPort: port
                )
            }
        }
        #expect(await transport.recordedOpenCalls().isEmpty)
        #expect(allocator.recordedPreferredPorts().isEmpty)
    }

    @Test("a busy remembered port fails instead of silently moving the browser address")
    func rememberedPortCollision() async throws {
        let transport = RecordingForwardingTransport(openSteps: [.portUnavailable])
        let allocator = ScriptedPortAllocator([49199])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        await #expect(throws: SSHLocalForwardingError.localPortUnavailable(49171)) {
            try await service.acquire(
                owner: UUID(), destination: "cluster", endpoint: endpoint, localPort: 49171
            )
        }
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49171])
        #expect(allocator.recordedPreferredPorts().isEmpty)
        await service.shutdown()
        #expect(await transport.recordedCancelCalls().isEmpty)
    }

    @Test("failed repair retains the assigned port and existing owner for a later shared retry")
    func failedRepairPreservesDesiredRoute() async throws {
        let transport = RecordingForwardingTransport(openSteps: [.succeed, .portUnavailable, .succeed])
        let allocator = ScriptedPortAllocator([49172, 49199])
        // After failed repair a listener may belong to a different process. It
        // must not be mistaken for this route even with a live SSH master.
        let probe = ScriptedListenerProbe([false, true])
        let service = makeService(transport: transport, allocator: allocator, listenerProbe: probe)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        let firstOwner = UUID()
        let secondOwner = UUID()
        let original = try await service.acquire(
            owner: firstOwner, destination: "cluster", endpoint: endpoint
        )
        await #expect(throws: SSHLocalForwardingError.localPortUnavailable(49172)) {
            try await service.acquire(owner: firstOwner, destination: "cluster", endpoint: endpoint)
        }
        let recovered = try await service.acquire(
            owner: secondOwner, destination: "cluster", endpoint: endpoint
        )
        #expect(recovered == original)
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49172, 49172, 49172])
        #expect(allocator.recordedPreferredPorts() == [8080])
        #expect(probe.recordedPorts() == [49172])
        await service.release(owner: secondOwner)
        #expect(await transport.recordedCancelCalls().count == 1)
        await service.release(owner: firstOwner)
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [49172, 49172])
    }

    @Test("conflicting concurrent remembered ports cannot replace another owner's route")
    func conflictingRememberedPorts() async throws {
        let transport = RecordingForwardingTransport(pausesFirstOpen: true)
        let allocator = ScriptedPortAllocator([])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        let owner = UUID()
        let first = Task {
            try await service.acquire(
                owner: owner, destination: "cluster", endpoint: endpoint, localPort: 49173
            )
        }
        await transport.waitUntilOpenCallCount(1)
        let conflict = Task {
            try await service.acquire(
                owner: UUID(), destination: "cluster", endpoint: endpoint, localPort: 49174
            )
        }
        for _ in 0..<10 { await Task.yield() }
        await transport.resumeFirstOpen()
        #expect(try await first.value.port == 49173)
        await #expect(throws: SSHLocalForwardingError.localPortUnavailable(49174)) {
            try await conflict.value
        }
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49173])
        #expect(await transport.recordedCancelCalls().isEmpty)
        await service.release(owner: owner)
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [49173])
    }

    @Test("closing the owner during repair cleans up a successfully reopened route")
    func releaseDuringRepair() async throws {
        let transport = RecordingForwardingTransport(masterRunning: false, pausesFirstCancel: true)
        let allocator = ScriptedPortAllocator([49175])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        let owner = UUID()
        _ = try await service.acquire(owner: owner, destination: "cluster", endpoint: endpoint)
        let repair = Task {
            try await service.acquire(owner: owner, destination: "cluster", endpoint: endpoint)
        }
        await transport.waitUntilCancelCallCount(1)
        await service.release(owner: owner)
        await transport.resumeFirstCancel()
        await #expect(throws: CancellationError.self) { try await repair.value }
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49175, 49175])
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [49175, 49175])
    }

    @Test("shutdown after failed repair clears desired routes without recreating listeners")
    func shutdownAfterFailedRepair() async throws {
        let transport = RecordingForwardingTransport(
            openSteps: [.succeed, .fail], masterRunning: false
        )
        let allocator = ScriptedPortAllocator([49176])
        let service = makeService(transport: transport, allocator: allocator)
        let endpoint = try #require(LoopbackURL("http://localhost:8080/"))
        let owner = UUID()
        _ = try await service.acquire(owner: owner, destination: "cluster", endpoint: endpoint)
        await #expect(throws: SSHLocalForwardingError.unableToOpenForward) {
            try await service.acquire(owner: owner, destination: "cluster", endpoint: endpoint)
        }
        await service.shutdown()
        await #expect(throws: SSHLocalForwardingError.shuttingDown) {
            try await service.acquire(
                owner: owner, destination: "cluster", endpoint: endpoint, localPort: 49176
            )
        }
        #expect(await transport.recordedOpenCalls().map(\.localPort) == [49176, 49176])
        #expect(await transport.recordedCancelCalls().map(\.localPort) == [49176, 49176])
    }

    private func makeService(
        transport: RecordingForwardingTransport,
        allocator: ScriptedPortAllocator,
        listenerProbe: ScriptedListenerProbe = ScriptedListenerProbe([])
    ) -> SSHLocalForwardingService {
        SSHLocalForwardingService(
            transport: transport,
            portAllocator: allocator,
            listenerProbe: listenerProbe
        )
    }
}

private struct ForwardCall: Equatable, Sendable {
    let alias: String
    let localPort: Int
    let remoteHost: String
    let remotePort: Int
}

private enum ForwardEvent: Equatable, Sendable {
    case open(Int)
    case cancelStarted(Int)
    case cancelFinished(Int)
}

private struct EndpointSelectingTransport: SSHLocalForwardingTransport {
    let base: RecordingForwardingTransport
    let connections: [CodexNotificationSSHEndpoint: RecordingForwardingTransport]

    func connection(for endpoint: CodexNotificationSSHEndpoint?) throws -> any SSHLocalForwardingTransport {
        guard let endpoint else { return base }
        guard let connection = connections[endpoint] else {
            throw SSHLocalForwardingError.unableToOpenForward
        }
        return connection
    }

    func openLocalForward(alias: String, localPort: Int, remoteHost: String, remotePort: Int) async throws {
        try await base.openLocalForward(alias: alias, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    func cancelLocalForward(alias: String, localPort: Int, remoteHost: String, remotePort: Int) async {
        await base.cancelLocalForward(alias: alias, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    func isMasterRunning(alias: String) async -> Bool {
        await base.isMasterRunning(alias: alias)
    }
}

private actor RecordingForwardingTransport: SSHLocalForwardingTransport {
    enum OpenStep: Sendable {
        case succeed
        case portUnavailable
        case fail
    }

    private var openSteps: [OpenStep]
    private var openCalls: [ForwardCall] = []
    private var cancelCalls: [ForwardCall] = []
    private var events: [ForwardEvent] = []
    private var masterChecks: [String] = []
    private var masterRunning: Bool
    private var shouldPauseFirstOpen: Bool
    private var shouldPauseFirstCancel: Bool
    private var firstOpenContinuation: CheckedContinuation<Void, Never>?
    private var firstCancelContinuation: CheckedContinuation<Void, Never>?
    private var openCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var cancelCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    init(
        openSteps: [OpenStep] = [],
        masterRunning: Bool = true,
        pausesFirstOpen: Bool = false,
        pausesFirstCancel: Bool = false
    ) {
        self.openSteps = openSteps
        self.masterRunning = masterRunning
        shouldPauseFirstOpen = pausesFirstOpen
        shouldPauseFirstCancel = pausesFirstCancel
    }

    func openLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async throws {
        openCalls.append(ForwardCall(
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        ))
        events.append(.open(localPort))
        let satisfied = openCountWaiters.filter { $0.0 <= openCalls.count }
        openCountWaiters.removeAll { $0.0 <= openCalls.count }
        satisfied.forEach { $0.1.resume() }

        if shouldPauseFirstOpen {
            shouldPauseFirstOpen = false
            await withCheckedContinuation { continuation in
                firstOpenContinuation = continuation
            }
        }

        let step = openSteps.isEmpty ? .succeed : openSteps.removeFirst()
        switch step {
        case .succeed:
            return
        case .portUnavailable:
            throw SSHLocalForwardingError.localPortUnavailable(localPort)
        case .fail:
            throw ForwardingTestError.transportFailure
        }
    }

    func cancelLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async {
        cancelCalls.append(ForwardCall(
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        ))
        events.append(.cancelStarted(localPort))
        let satisfied = cancelCountWaiters.filter { $0.0 <= cancelCalls.count }
        cancelCountWaiters.removeAll { $0.0 <= cancelCalls.count }
        satisfied.forEach { $0.1.resume() }

        if shouldPauseFirstCancel {
            shouldPauseFirstCancel = false
            await withCheckedContinuation { continuation in
                firstCancelContinuation = continuation
            }
        }
        events.append(.cancelFinished(localPort))
    }

    func isMasterRunning(alias: String) -> Bool {
        masterChecks.append(alias)
        return masterRunning
    }

    func recordedOpenCalls() -> [ForwardCall] {
        openCalls
    }

    func recordedCancelCalls() -> [ForwardCall] {
        cancelCalls
    }

    func recordedMasterChecks() -> [String] {
        masterChecks
    }

    func recordedEvents() -> [ForwardEvent] {
        events
    }

    func waitUntilOpenCallCount(_ count: Int) async {
        guard openCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            openCountWaiters.append((count, continuation))
        }
    }

    func resumeFirstOpen() {
        firstOpenContinuation?.resume()
        firstOpenContinuation = nil
    }

    func waitUntilCancelCallCount(_ count: Int) async {
        guard cancelCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            cancelCountWaiters.append((count, continuation))
        }
    }

    func resumeFirstCancel() {
        firstCancelContinuation?.resume()
        firstCancelContinuation = nil
    }
}

private enum ForwardingTestError: Error, Sendable {
    case transportFailure
}

private actor CompletionFlag {
    private var isComplete = false

    func mark() {
        isComplete = true
    }

    func value() -> Bool {
        isComplete
    }
}

private final class ScriptedPortAllocator: SSHLocalPortAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [Int]
    private var preferredPorts: [Int?] = []

    init(_ ports: [Int]) {
        self.ports = ports
    }

    func availablePort(
        preferredPort: Int?,
        excluding excludedPorts: Set<Int>
    ) throws -> Int {
        try lock.withLock {
            preferredPorts.append(preferredPort)
            guard !ports.isEmpty else {
                throw SSHLocalForwardingError.unableToAllocateLocalPort
            }
            return ports.removeFirst()
        }
    }

    func recordedPreferredPorts() -> [Int?] {
        lock.withLock { preferredPorts }
    }
}

private final class ScriptedListenerProbe: SSHLocalListenerProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var ports: [Int] = []

    init(_ results: [Bool]) {
        self.results = results
    }

    func isListening(port: Int) -> Bool {
        lock.withLock {
            ports.append(port)
            return results.isEmpty ? false : results.removeFirst()
        }
    }

    func recordedPorts() -> [Int] {
        lock.withLock { ports }
    }
}
