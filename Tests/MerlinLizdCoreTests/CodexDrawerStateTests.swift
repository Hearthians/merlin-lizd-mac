import Testing
@testable import MerlinLizdCore

@Suite("Codex drawer state")
struct CodexDrawerStateTests {
    @Test("idle, active, and expanded drawer heights preserve the terminal")
    func computesDrawerHeight() {
        let key = Self.key(1)
        var state = CodexDrawerState()
        state.reduce(.selectTerminal(.connected(key)))

        #expect(state.height(in: 1_000) == 42)

        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .thinking, active: false),
        ]))
        #expect(state.height(in: 1_000) == 92)

        state.reduce(.setExpanded(true))
        state.reduce(.resizeExpanded(fraction: 0.1))
        #expect(state.height(in: 1_000) == 200)
        state.reduce(.resizeExpanded(fraction: 0.9))
        #expect(state.height(in: 1_000) == 500)
    }

    @Test("composer follows conversation identity and submits or steers")
    func scopesComposerAndPromptActions() {
        let first = Self.key(1)
        let second = Self.key(2)
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(first)))
        state.reduce(.editComposer(" start first "))

        #expect(state.reduce(.sendComposer) == [
            .submit(prompt: "start first", key: first),
        ])
        #expect(state.composer(for: first).isEmpty)

        state.reduce(.selectTerminal(.connected(second)))
        state.reduce(.editComposer("second draft"))
        state.reduce(.selectTerminal(.connected(first)))
        #expect(state.composer(for: first).isEmpty)
        state.reduce(.receiveSessions([
            first: Self.session(first, phase: .controlling, active: true),
        ]))
        state.reduce(.editComposer(" steer first "))
        #expect(state.reduce(.sendComposer) == [
            .steer(prompt: "steer first", key: first),
        ])

        state.reduce(.selectTerminal(.connected(second)))
        #expect(state.composer(for: second) == "second draft")
    }

    @Test("ineligible terminal states never produce Codex commands")
    func excludesIneligibleTerminals() {
        let key = Self.key(1)
        var state = CodexDrawerState(availability: .ready)

        for context in [
            CodexDrawerTerminalContext.plainLocalShell,
            .unresolvedTmux,
            .disconnected(key),
            .noSelection,
        ] {
            state.reduce(.selectTerminal(context))
            state.reduce(.editComposer("must not run"))
            #expect(state.reduce(.sendComposer).isEmpty)
            #expect(!state.canSend)
        }
    }

    @Test("takeover keeps Codex ownership until interruption completes")
    func sequencesTakeoverCompletion() {
        let key = Self.key(1)
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))

        #expect(state.keyboardOwnership == .codex)
        #expect(state.reduce(.requestTakeover) == [.stopAndTakeOver(key)])
        #expect(state.keyboardOwnership == .takeoverPending)
        #expect(state.reduce(.requestTakeover).isEmpty)

        state.reduce(.takeoverCompleted(key))
        #expect(state.keyboardOwnership == .user)
    }

    @Test("only pending approval requests can be allowed once or denied")
    func validatesApprovalActions() throws {
        let key = Self.key(1)
        let request = try Self.approval()
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: CodexSessionState(
                key: key,
                activeTurnID: .init(rawValue: "turn"),
                phase: .awaitingApproval,
                pendingApprovals: [request]
            ),
        ]))

        #expect(state.reduce(.allowOnce(request.id)) == [
            .allowOnce(request.id),
        ])
        #expect(state.reduce(.deny(request.id)) == [.deny(request.id)])
        #expect(state.reduce(.allowOnce(terminalUUID(
            "99999999-9999-9999-9999-999999999999"
        ))).isEmpty)

        state.reduce(.selectTerminal(.disconnected(key)))
        #expect(state.reduce(.allowOnce(request.id)).isEmpty)
        #expect(state.reduce(.deny(request.id)) == [.deny(request.id)])
    }

    @Test("matching tmux tabs share badges while other sessions stay independent")
    func aggregatesBadgesByConversation() throws {
        let shared = Self.key(1)
        let other = Self.key(2)
        let request = try Self.approval()
        var state = CodexDrawerState()
        state.reduce(.receiveSessions([
            shared: CodexSessionState(
                key: shared,
                activeTurnID: .init(rawValue: "one"),
                phase: .awaitingApproval,
                pendingApprovals: [request]
            ),
            other: Self.session(other, phase: .thinking, active: true),
        ]))
        let tabs = [
            Self.tab("a", key: shared),
            Self.tab("b", key: shared),
            Self.tab("c", key: other),
            TerminalTabRecord(
                id: "local-shell",
                title: "Local",
                target: .local,
                sessionName: nil
            ),
        ]

        let badges = state.badges(for: tabs)
        #expect(badges["a"] == badges["b"])
        #expect(badges["a"] == CodexDrawerBadge(
            phase: .awaitingApproval,
            approvalCount: 1
        ))
        #expect(badges["c"] == CodexDrawerBadge(
            phase: .running,
            approvalCount: 0
        ))
        #expect(badges["local-shell"] == nil)
        #expect(state.backgroundActivity(excluding: shared) ==
            CodexDrawerBackgroundActivity(
                runningConversationCount: 1,
                approvalConversationCount: 0,
                pendingApprovalCount: 0
            ))
        #expect(state.backgroundActivity(excluding: other) ==
            CodexDrawerBackgroundActivity(
                runningConversationCount: 0,
                approvalConversationCount: 1,
                pendingApprovalCount: 1
            ))
    }

    @Test("retryable availability failures use bounded non-sensitive text")
    func presentsAvailabilityFailure() {
        let raw = String(repeating: "private stderr ", count: 200)
        var state = CodexDrawerState(
            availability: .capabilityUnavailable(raw)
        )

        #expect(state.availabilityNotice?.isRetryable == true)
        #expect(state.availabilityNotice?.message.count ?? 0 < 160)
        #expect(state.availabilityNotice?.message.contains(raw) == false)
        #expect(state.reduce(.retryAvailability) == [.retryAvailability])

        state.reduce(.receiveAvailability(.unsupportedVersion(raw)))
        #expect(state.availabilityNotice?.isRetryable == false)
        #expect(state.reduce(.retryAvailability).isEmpty)
    }

    @Test("active drawer describes current action and steering")
    func describesCurrentAction() {
        let key = Self.key(1)
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))

        #expect(state.currentAction == "Operating the visible terminal")
        #expect(state.composerMode == .steer)
    }

    private static func key(_ number: Int64) -> TerminalConversationKey {
        TerminalConversationKey(
            target: .local,
            tmux: .init(
                serverSessionID: "$\(number)",
                createdAtEpoch: number
            )
        )
    }

    private static func session(
        _ key: TerminalConversationKey,
        phase: CodexSessionPhase,
        active: Bool
    ) -> CodexSessionState {
        CodexSessionState(
            key: key,
            activeTurnID: active ? .init(rawValue: "turn") : nil,
            phase: phase
        )
    }

    private static func tab(
        _ id: String,
        key: TerminalConversationKey
    ) -> TerminalTabRecord {
        TerminalTabRecord(
            id: id,
            title: id,
            target: .local,
            sessionName: "session",
            tmuxIdentity: key.tmux
        )
    }

    private static func approval() throws -> TerminalApprovalRequest {
        let endpointID = terminalTestEndpoint(
            "11111111-1111-1111-1111-111111111111"
        )
        let batch = TerminalInputBatch(
            expectedRevision: 42,
            events: [.text("rm -rf /tmp/example")],
            purpose: "Remove generated files",
            declaredRisk: .high
        )
        return TerminalApprovalRequest(
            scope: try TerminalApprovalScope(
                batch: batch,
                endpointID: endpointID,
                screenRevision: 42
            ),
            batch: batch,
            reason: "Destructive terminal input"
        )
    }
}
