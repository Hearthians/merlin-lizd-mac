import Testing
@testable import MerlinLizdCore

@Suite("Terminal approval", .serialized)
struct TerminalApprovalBrokerTests {
    @Test("pending request observation is signalled without scheduler polling")
    func signalsPendingRequestObservation() async throws {
        let broker = TerminalApprovalBroker()
        let request = try approvalRequest()
        async let observed = broker.waitUntilPending(
            request.id,
            timeout: .seconds(1)
        )
        let waiter = Task {
            try await awaitLiveApproval(
                broker,
                request: request,
                turnID: "observed"
            )
        }

        #expect(await observed)
        await broker.cancelTurn("observed")
        await #expect(throws: TerminalApprovalError.cancelled) {
            try await waiter.value
        }
    }

    @Test("pending request observation has a deterministic deadline")
    func pendingRequestObservationTimesOut() async {
        let broker = TerminalApprovalBroker()

        #expect(
            await !broker.waitUntilPending(
                terminalUUID(),
                timeout: .milliseconds(10)
            )
        )
    }

    @Test("canonical payload bytes use sorted-key JSON before SHA-256")
    func canonicalizesExactPayload() throws {
        let batch = terminalTestBatch()
        let bytes = try TerminalApprovalScope.canonicalPayloadBytes(for: batch)
        let scope = try TerminalApprovalScope(
            batch: batch,
            endpointID: terminalTestEndpoint(),
            screenRevision: 7
        )

        #expect(
            terminalUTF8String(bytes)
                == #"{"declaredRisk":1,"events":[{"text":{"_0":"echo ok"}}],"expectedRevision":7,"purpose":"routine typing"}"#
        )
        #expect(
            scope.payloadDigest
                == "3c9b63d7bb1a5829376c21ffa593affaece2b07a1cb33f651129d32aebf1fad6"
        )
    }

    @Test("approve once grants exactly one matching canonical scope")
    func consumesExactGrantOnce() async throws {
        let broker = TerminalApprovalBroker()
        let request = try approvalRequest()
        let waiter = Task {
            try await awaitLiveApproval(
                broker,
                request: request,
                turnID: "turn-1"
            )
        }
        #expect(await waitForPendingApproval(request.id, in: broker))

        #expect(await broker.approveOnce(request.id))
        let grant = try await waiter.value
        #expect(await broker.consume(grant, matching: request.scope))
        #expect(await !broker.consume(grant, matching: request.scope))
        #expect(await !broker.approveOnce(request.id))
    }

    @Test("payload endpoint and revision mismatches consume the grant fail closed")
    func rejectsAnyScopeMismatch() async throws {
        let broker = TerminalApprovalBroker()
        let request = try approvalRequest()
        let mismatches = [
            try TerminalApprovalScope(
                batch: terminalTestBatch(events: [.text("echo changed")]),
                endpointID: request.scope.endpointID,
                screenRevision: request.scope.screenRevision
            ),
            try TerminalApprovalScope(
                batch: request.batch,
                endpointID: terminalTestEndpoint(
                    "00000000-0000-0000-0000-000000000002"
                ),
                screenRevision: request.scope.screenRevision
            ),
            try TerminalApprovalScope(
                batch: request.batch,
                endpointID: request.scope.endpointID,
                screenRevision: request.scope.screenRevision + 1
            ),
        ]

        for (index, mismatch) in mismatches.enumerated() {
            let candidate = TerminalApprovalRequest(
                id: terminalUUID(),
                scope: request.scope,
                batch: request.batch,
                reason: "high risk"
            )
            let waiter = Task {
                try await awaitLiveApproval(
                    broker,
                    request: candidate,
                    turnID: "turn-\(index)"
                )
            }
            #expect(await waitForPendingApproval(candidate.id, in: broker))
            #expect(await broker.approveOnce(candidate.id))
            let grant = try await waiter.value

            #expect(await !broker.consume(grant, matching: mismatch))
            #expect(await !broker.consume(grant, matching: candidate.scope))
        }
    }

    @Test("route and screen changes expire pending and approved requests")
    func invalidationExpiresApproval() async throws {
        let broker = TerminalApprovalBroker()
        let routeRequest = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000002"
        )
        let screenRequest = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000003"
        )
        let routeWaiter = Task {
            try await awaitLiveApproval(
                broker,
                request: routeRequest,
                turnID: "route"
            )
        }
        let screenWaiter = Task {
            try await awaitLiveApproval(
                broker,
                request: screenRequest,
                turnID: "screen"
            )
        }
        #expect(await waitForPendingApproval(routeRequest.id, in: broker))
        #expect(await waitForPendingApproval(screenRequest.id, in: broker))

        await broker.invalidateRoute(routeRequest.scope.endpointID)
        await broker.invalidateScreen(
            endpointID: screenRequest.scope.endpointID,
            currentRevision: screenRequest.scope.screenRevision + 1
        )

        await #expect(throws: TerminalApprovalError.expired) {
            try await routeWaiter.value
        }
        await #expect(throws: TerminalApprovalError.expired) {
            try await screenWaiter.value
        }

        let approved = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000004"
        )
        let approvedWaiter = Task {
            try await awaitLiveApproval(
                broker,
                request: approved,
                turnID: "approved"
            )
        }
        #expect(await waitForPendingApproval(approved.id, in: broker))
        #expect(await broker.approveOnce(approved.id))
        let grant = try await approvedWaiter.value
        await broker.invalidateScreen(
            endpointID: approved.scope.endpointID,
            currentRevision: approved.scope.screenRevision + 1
        )
        #expect(await !broker.consume(grant, matching: approved.scope))
    }

    @Test("denial and turn cancellation resolve every stored continuation")
    func deniesAndCancels() async throws {
        let broker = TerminalApprovalBroker()
        let denied = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000005"
        )
        let cancelled = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000006"
        )
        let deniedWaiter = Task {
            try await awaitLiveApproval(
                broker,
                request: denied,
                turnID: "turn-denied"
            )
        }
        let cancelledWaiter = Task {
            try await awaitLiveApproval(
                broker,
                request: cancelled,
                turnID: "turn-cancelled"
            )
        }
        #expect(await waitForPendingApproval(denied.id, in: broker))
        #expect(await waitForPendingApproval(cancelled.id, in: broker))

        #expect(await broker.deny(denied.id))
        await broker.cancelTurn("turn-cancelled")

        await #expect(throws: TerminalApprovalError.denied) {
            try await deniedWaiter.value
        }
        await #expect(throws: TerminalApprovalError.cancelled) {
            try await cancelledWaiter.value
        }
        #expect(await broker.pendingRequests().isEmpty)
    }

    @Test("a request ID owns at most one continuation")
    func rejectsDuplicateContinuation() async throws {
        let broker = TerminalApprovalBroker()
        let request = try approvalRequest()
        let first = Task {
            try await awaitLiveApproval(
                broker,
                request: request,
                turnID: "turn-1"
            )
        }
        #expect(await waitForPendingApproval(request.id, in: broker))

        await #expect(throws: TerminalApprovalError.duplicateRequest) {
            try await awaitLiveApproval(
                broker,
                request: request,
                turnID: "turn-2"
            )
        }
        await broker.cancelTurn("turn-1")
        await #expect(throws: TerminalApprovalError.cancelled) {
            try await first.value
        }
    }

    @Test("mismatched request scope is rejected before becoming pending")
    func rejectsForgedRequestScope() async throws {
        let broker = TerminalApprovalBroker()
        let valid = try approvalRequest()
        let forged = TerminalApprovalRequest(
            id: terminalUUID("20000000-0000-0000-0000-000000000007"),
            scope: valid.scope,
            batch: terminalTestBatch(
                events: [.text("echo substituted payload")],
                risk: .high
            ),
            reason: "forged"
        )

        await #expect(throws: TerminalApprovalError.invalidRequest) {
            try await awaitLiveApproval(
                broker,
                request: forged,
                turnID: "forged"
            )
        }
        #expect(await broker.pendingRequests().isEmpty)
        #expect(await !broker.approveOnce(forged.id))
    }

    @Test("live approval rejects legacy context before becoming pending")
    func rejectsLegacyLiveApproval() async throws {
        let broker = TerminalApprovalBroker()
        let valid = try approvalRequest()
        let legacy = TerminalApprovalRequest(
            id: valid.id,
            scope: try TerminalApprovalScope(
                batch: valid.batch,
                endpointID: valid.scope.endpointID,
                screenRevision: valid.scope.screenRevision
            ),
            batch: valid.batch,
            reason: valid.reason
        )

        await #expect(throws: TerminalApprovalError.invalidRequest) {
            try await broker.awaitApproval(
                for: legacy,
                endpointID: legacy.scope.endpointID,
                screen: approvalScreen(),
                surface: approvalSurface(),
                turnID: "legacy"
            )
        }
        #expect(await broker.pendingRequests().isEmpty)
    }

    @Test("live approval rejects forged endpoint revision screen or surface")
    func rejectsForgedLiveContext() async throws {
        let broker = TerminalApprovalBroker()
        let valid = try approvalRequest()
        let forgedScreen = terminalTestScreen(
            revision: valid.batch.expectedRevision,
            text: "forged approval-time screen"
        )
        let forgedSurface = TmuxSurface(
            sessionIdentity: approvalSurface().sessionIdentity,
            windowID: "@9",
            paneID: "%9",
            currentCommand: "bash"
        )
        let forgedScopes = [
            try TerminalApprovalScope(
                batch: valid.batch,
                endpointID: terminalTestEndpoint(
                    "00000000-0000-0000-0000-000000000002"
                ),
                screen: approvalScreen(),
                surface: approvalSurface()
            ),
            try TerminalApprovalScope(
                batch: valid.batch,
                endpointID: valid.scope.endpointID,
                screen: terminalTestScreen(
                    revision: valid.scope.screenRevision + 1
                ),
                surface: approvalSurface()
            ),
            try TerminalApprovalScope(
                batch: valid.batch,
                endpointID: valid.scope.endpointID,
                screen: forgedScreen,
                surface: approvalSurface()
            ),
            try TerminalApprovalScope(
                batch: valid.batch,
                endpointID: valid.scope.endpointID,
                screen: approvalScreen(),
                surface: forgedSurface
            ),
        ]

        for scope in forgedScopes {
            let forged = TerminalApprovalRequest(
                id: terminalUUID(),
                scope: scope,
                batch: valid.batch,
                reason: valid.reason
            )
            await #expect(throws: TerminalApprovalError.invalidRequest) {
                try await awaitLiveApproval(
                    broker,
                    request: forged,
                    turnID: "forged-context"
                )
            }
            #expect(await broker.pendingRequests().isEmpty)
        }
    }

    @Test("direct task cancellation revokes a racing allow-once grant")
    func cancellationWinsBeforeApprovalDelivery() async throws {
        let broker = TerminalApprovalBroker()
        let request = try approvalRequest(
            id: "20000000-0000-0000-0000-000000000008"
        )
        let waiter = Task {
            try await awaitLiveApproval(
                broker,
                request: request,
                turnID: "race"
            )
        }
        #expect(await waitForPendingApproval(request.id, in: broker))

        waiter.cancel()
        let didApprove = await broker.approveOnce(request.id)

        #expect(!didApprove)
        await #expect(throws: TerminalApprovalError.cancelled) {
            try await waiter.value
        }
        #expect(await broker.pendingRequests().isEmpty)
    }

    private func approvalRequest(
        id: String = "20000000-0000-0000-0000-000000000001"
    ) throws -> TerminalApprovalRequest {
        let batch = terminalTestBatch(
            events: [.text("git push origin main")],
            risk: .high
        )
        return TerminalApprovalRequest(
            id: terminalUUID(id),
            scope: try TerminalApprovalScope(
                batch: batch,
                endpointID: terminalTestEndpoint(),
                screen: approvalScreen(),
                surface: approvalSurface()
            ),
            batch: batch,
            reason: "git push changes a remote repository"
        )
    }

    private func awaitLiveApproval(
        _ broker: TerminalApprovalBroker,
        request: TerminalApprovalRequest,
        turnID: String
    ) async throws -> TerminalApprovalGrant {
        try await broker.awaitApproval(
            for: request,
            endpointID: terminalTestEndpoint(),
            screen: approvalScreen(),
            surface: approvalSurface(),
            turnID: turnID
        )
    }

    private func approvalScreen() -> TerminalScreenSnapshot {
        terminalTestScreen(revision: 7)
    }

    private func approvalSurface() -> TmuxSurface {
        TmuxSurface(
            sessionIdentity: terminalTestConversationKey().tmux,
            windowID: "@1",
            paneID: "%1",
            currentCommand: "zsh"
        )
    }
}
