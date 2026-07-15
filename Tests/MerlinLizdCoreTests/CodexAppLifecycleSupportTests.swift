import Testing
@testable import MerlinLizdCore

@Suite("Codex app lifecycle support", .serialized)
struct CodexAppLifecycleSupportTests {
    @Test("focus effects serialize and finish on the latest endpoint")
    func latestFocusWinsAfterOlderEffectCompletesLate() async {
        let recorder = GatedEndpointFocusRecorder()
        let arbiter = TerminalEndpointFocusArbiter { endpointID in
            await recorder.focus(endpointID)
        }
        let firstID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        let secondID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())

        let first = Task {
            await arbiter.requestFocus(firstID, revision: 1)
        }
        await recorder.waitForCallCount(1)
        let second = Task {
            await arbiter.requestFocus(secondID, revision: 2)
        }
        await second.value
        await recorder.releaseFirst()
        await first.value

        #expect(await recorder.calls == [firstID, secondID])
    }

    @Test("older focus publication is ignored when it arrives last")
    func focusRevisionWinsWhenTaskArrivalIsReversed() async {
        let recorder = GatedEndpointFocusRecorder()
        let arbiter = TerminalEndpointFocusArbiter { endpointID in
            await recorder.focus(endpointID)
        }
        let firstID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        let secondID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())

        let second = Task {
            await arbiter.requestFocus(secondID, revision: 2)
        }
        await recorder.waitForCallCount(1)
        await recorder.releaseFirst()
        await second.value
        await arbiter.requestFocus(firstID, revision: 1)

        #expect(await recorder.calls == [secondID])
    }

    @Test("authoritative reconciliation retires absent notification ids")
    func reconciliationRemovesStaleNotificationClickTargets() throws {
        let key = TerminalConversationKey(
            target: .local,
            tmux: .init(serverSessionID: "$1", createdAtEpoch: 1)
        )
        let stale = try approvalRequest()
        let current = try approvalRequest()
        var tracker = CodexApprovalNotificationTracker(limit: 128)

        let first = tracker.consume(
            .approvalRequested(key: key, request: stale, revision: 1),
            foreground: nil
        )
        #expect(first.map(\.identifier) == [stale.id.uuidString])
        #expect(tracker.conversation(for: stale.id.uuidString) == key)

        let snapshot = CodexSessionActivitySnapshot(
            revision: 2,
            states: [key: CodexSessionState(
                key: key,
                pendingApprovals: [current]
            )]
        )
        let reconciled = tracker.consume(
            .transitionHistoryGap(snapshot),
            foreground: nil
        )

        #expect(tracker.conversation(for: stale.id.uuidString) == nil)
        #expect(tracker.conversation(for: current.id.uuidString) == key)
        #expect(reconciled.map(\.identifier) == [current.id.uuidString])
    }

    private func approvalRequest() throws -> TerminalApprovalRequest {
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        let batch = TerminalInputBatch(
            expectedRevision: 7,
            events: [.text("safe")],
            purpose: "test",
            declaredRisk: .routine
        )
        return TerminalApprovalRequest(
            scope: try TerminalApprovalScope(
                batch: batch,
                endpointID: endpointID,
                screenRevision: 7
            ),
            batch: batch,
            reason: "test"
        )
    }
}

private actor GatedEndpointFocusRecorder {
    private(set) var calls: [TerminalEndpointID] = []
    private var firstGate: CheckedContinuation<Void, Never>?
    private var callWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    func focus(_ endpointID: TerminalEndpointID) async {
        calls.append(endpointID)
        resumeCallWaiters()
        if calls.count == 1 {
            await withCheckedContinuation { firstGate = $0 }
        }
    }

    func waitForCallCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }

    private func resumeCallWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if calls.count >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        callWaiters = retained
    }
}
