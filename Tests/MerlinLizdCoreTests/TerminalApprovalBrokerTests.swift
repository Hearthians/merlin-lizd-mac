import Testing
@testable import MerlinLizdCore

@Suite("Terminal approval", .serialized)
struct TerminalApprovalBrokerTests {
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
            try await broker.awaitApproval(for: request, turnID: "turn-1")
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
                try await broker.awaitApproval(
                    for: candidate,
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
            try await broker.awaitApproval(for: routeRequest, turnID: "route")
        }
        let screenWaiter = Task {
            try await broker.awaitApproval(for: screenRequest, turnID: "screen")
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
            try await broker.awaitApproval(for: approved, turnID: "approved")
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
            try await broker.awaitApproval(for: denied, turnID: "turn-denied")
        }
        let cancelledWaiter = Task {
            try await broker.awaitApproval(
                for: cancelled,
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
            try await broker.awaitApproval(for: request, turnID: "turn-1")
        }
        #expect(await waitForPendingApproval(request.id, in: broker))

        await #expect(throws: TerminalApprovalError.duplicateRequest) {
            try await broker.awaitApproval(for: request, turnID: "turn-2")
        }
        await broker.cancelTurn("turn-1")
        await #expect(throws: TerminalApprovalError.cancelled) {
            try await first.value
        }
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
                screenRevision: batch.expectedRevision
            ),
            batch: batch,
            reason: "git push changes a remote repository"
        )
    }
}
