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
            .notStarted(key),
            .endpointRegistering(key),
            .registrationFailed(key),
            .detached(key),
            .exited(key),
            .closed(key),
            .reconnecting(key),
            .disconnected(key),
            .noSelection,
        ] {
            state.reduce(.selectTerminal(context))
            state.reduce(.editComposer("must not run"))
            #expect(state.reduce(.sendComposer).isEmpty)
            #expect(!state.canSend)
        }
    }

    @Test("endpoint readiness fails closed until exact registration succeeds")
    func projectsEndpointReadiness() {
        let key = Self.key(1)

        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .missing,
            endpoint: .notStarted,
            isReconnecting: false
        ) == .notStarted(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .running,
            endpoint: .registering,
            isReconnecting: false
        ) == .endpointRegistering(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .running,
            endpoint: .registrationFailed,
            isReconnecting: false
        ) == .registrationFailed(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .running,
            endpoint: .registered,
            isReconnecting: false
        ) == .connected(key))

        // A restored identity with no live session and a late detach must never
        // project as connected merely because the key is known.
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .missing,
            endpoint: .registrationFailed,
            isReconnecting: false
        ) == .registrationFailed(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .running,
            endpoint: .detached,
            isReconnecting: false
        ) == .detached(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .exited,
            endpoint: .registered,
            isReconnecting: false
        ) == .exited(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .closed,
            endpoint: .registered,
            isReconnecting: false
        ) == .closed(key))
        #expect(CodexDrawerTerminalContext.project(
            key: key,
            session: .running,
            endpoint: .registering,
            isReconnecting: true
        ) == .reconnecting(key))

        let preparing = CodexDrawerState(
            terminalContext: .endpointRegistering(key)
        ).terminalNotice
        let retrying = CodexDrawerState(
            terminalContext: .reconnecting(key)
        ).terminalNotice
        let failed = CodexDrawerState(
            terminalContext: .registrationFailed(key)
        ).terminalNotice
        #expect(preparing != retrying)
        #expect(preparing != failed)
        #expect(retrying != failed)
    }

    @Test("endpoint registration ignores late failure and detach races")
    func reducesEndpointRegistrationRaces() {
        let first = terminalUUID("10000000-0000-0000-0000-000000000001")
        let second = terminalUUID("10000000-0000-0000-0000-000000000002")
        let originalRoute = Self.endpointRoute(sessionName: "original")
        let renamedRoute = Self.endpointRoute(sessionName: "renamed")
        var registration = CodexDrawerEndpointRegistration()

        registration.begin(generationID: first, route: originalRoute)
        #expect(registration.readiness == .registering)
        registration.detach()
        let lateSuccess = registration.succeed(
            generationID: first,
            route: originalRoute
        )
        #expect(!lateSuccess)
        #expect(registration.readiness == .detached)

        registration.begin(generationID: second, route: renamedRoute)
        let staleFailure = registration.fail(
            generationID: first,
            route: originalRoute
        )
        #expect(!staleFailure)
        #expect(registration.readiness == .registering)
        let staleRouteSuccess = registration.succeed(
            generationID: second,
            route: originalRoute
        )
        #expect(!staleRouteSuccess)
        #expect(registration.readiness == .registering)
        let exactFailure = registration.fail(
            generationID: second,
            route: renamedRoute
        )
        #expect(exactFailure)
        #expect(registration.readiness == .registrationFailed)

        registration.begin(generationID: first, route: originalRoute)
        let exactSuccess = registration.succeed(
            generationID: first,
            route: originalRoute
        )
        #expect(exactSuccess)
        #expect(registration.readiness == .registered)
        #expect(registration.route == originalRoute)
    }

    @Test("endpoint route diff invalidates rename but ignores cosmetic title")
    func classifiesEndpointRouteChangesPerTab() {
        let identity = Self.key(1).tmux
        let previous = [
            Self.tab("first", key: Self.key(1), sessionName: "old"),
            Self.tab("duplicate", key: Self.key(1), sessionName: "old"),
            Self.tab("cosmetic", key: Self.key(2), sessionName: "stable"),
        ]
        var current = previous
        current[0].sessionName = "renamed"
        current[1].sessionName = "renamed"
        current[2].title = "A nicer title"

        #expect(
            CodexDrawerEndpointRouteChange.changedTabIDs(
                from: previous,
                to: current
            ) == Set(["first", "duplicate"])
        )
        #expect(CodexDrawerEndpointRouteDescriptor(tab: current[0]) ==
            CodexDrawerEndpointRouteDescriptor(
                target: .local,
                sessionName: "renamed",
                tmuxIdentity: identity
            ))
    }

    @Test("takeover keeps Codex ownership until interruption completes")
    func sequencesTakeoverCompletion() {
        let key = Self.key(1)
        let operationID = terminalUUID(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))

        #expect(state.keyboardOwnership == .codex)
        #expect(state.reduce(.requestTakeover(operationID)) == [
            .stopAndTakeOver(key, operationID),
        ])
        #expect(state.keyboardOwnership == .takeoverPending(operationID))
        #expect(state.reduce(.requestTakeover(operationID)).isEmpty)

        state.reduce(.takeoverCompleted(key, operationID))
        #expect(state.keyboardOwnership == .user)
    }

    @Test("takeover pending blocks sends without discarding the draft")
    func blocksSendWhileTakeoverIsPending() {
        let key = Self.key(1)
        let operationID = terminalUUID(
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        )
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))
        state.reduce(.editComposer("keep this draft"))

        #expect(state.reduce(.requestTakeover(operationID)) == [
            .stopAndTakeOver(key, operationID),
        ])
        #expect(!state.canSend)
        #expect(state.reduce(.sendComposer).isEmpty)
        #expect(state.composerText == "keep this draft")
        #expect(state.keyboardOwnership == .takeoverPending(operationID))
    }

    @Test("disconnected active turns remain stoppable without a terminal")
    func stopsDisconnectedActiveTurn() {
        let key = Self.key(1)
        let otherKey = Self.key(2)
        let operationID = terminalUUID(
            "cccccccc-cccc-cccc-cccc-cccccccccccc"
        )
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.disconnected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))

        #expect(state.canTakeOver)
        #expect(state.reduce(.requestTakeover(operationID)) == [
            .stopAndTakeOver(key, operationID),
        ])
        #expect(state.keyboardOwnership == .takeoverPending(operationID))
        #expect(state.reduce(.requestTakeover(operationID)).isEmpty)

        state.reduce(.selectTerminal(.connected(otherKey)))
        state.reduce(.selectTerminal(.disconnected(key)))
        #expect(state.keyboardOwnership == .takeoverPending(operationID))

        state.reduce(.receiveSessions([
            key: Self.session(
                key,
                phase: .failed(.interrupted),
                active: false
            ),
        ]))
        #expect(state.keyboardOwnership == .takeoverPending(operationID))
        state.reduce(.takeoverCompleted(key, operationID))
        #expect(state.keyboardOwnership == .user)
    }

    @Test("stale takeover completion cannot finish a newer operation")
    func rejectsStaleTakeoverCompletion() {
        let key = Self.key(1)
        let firstOperationID = terminalUUID(
            "dddddddd-dddd-dddd-dddd-dddddddddddd"
        )
        let secondOperationID = terminalUUID(
            "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        )
        var state = CodexDrawerState(availability: .ready)
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))

        state.reduce(.requestTakeover(firstOperationID))
        state.reduce(.takeoverCompleted(key, firstOperationID))
        state.reduce(.receiveSessions([
            key: Self.session(key, phase: .controlling, active: true),
        ]))
        state.reduce(.requestTakeover(secondOperationID))

        state.reduce(.takeoverCompleted(key, firstOperationID))
        #expect(state.keyboardOwnership ==
            .takeoverPending(secondOperationID))
        state.reduce(.takeoverCompleted(key, secondOperationID))
        #expect(state.keyboardOwnership == .user)
    }

    @Test("takeover completion action is sequenced after coordinator stop")
    func sequencesAsyncTakeoverCommand() async {
        let key = Self.key(1)
        let operationID = terminalUUID(
            "ffffffff-ffff-ffff-ffff-ffffffffffff"
        )
        let gate = AsyncStartGate()
        let completion = AsyncCompletionProbe()
        let execution = Task {
            let action = await CodexDrawerCommandSequencer.stopAndTakeOver(
                key,
                operationID: operationID
            ) {
                await gate.wait()
            }
            await completion.complete()
            return action
        }

        await gate.waitUntilEntered()
        #expect(await completion.count() == 0)
        await gate.open()
        #expect(await execution.value ==
            .takeoverCompleted(key, operationID))
        #expect(await completion.count() == 1)
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

        let legacy = TerminalApprovalRequest(
            scope: try TerminalApprovalScope(
                batch: request.batch,
                endpointID: request.scope.endpointID,
                screenRevision: request.scope.screenRevision
            ),
            batch: request.batch,
            reason: "Legacy request without verified context"
        )
        state.reduce(.selectTerminal(.connected(key)))
        state.reduce(.receiveSessions([
            key: CodexSessionState(
                key: key,
                activeTurnID: .init(rawValue: "turn"),
                phase: .awaitingApproval,
                pendingApprovals: [legacy]
            ),
        ]))
        #expect(state.reduce(.allowOnce(legacy.id)).isEmpty)
        #expect(state.reduce(.deny(legacy.id)) == [.deny(legacy.id)])
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
        key: TerminalConversationKey,
        sessionName: String = "session"
    ) -> TerminalTabRecord {
        TerminalTabRecord(
            id: id,
            title: id,
            target: .local,
            sessionName: sessionName,
            tmuxIdentity: key.tmux
        )
    }

    private static func endpointRoute(
        sessionName: String
    ) -> CodexDrawerEndpointRouteDescriptor {
        CodexDrawerEndpointRouteDescriptor(
            target: .local,
            sessionName: sessionName,
            tmuxIdentity: key(1).tmux
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
        let screen = TerminalScreenSnapshot(
            revision: 42,
            columns: 80,
            rows: 24,
            cursor: TerminalCursor(row: 3, column: 9, isVisible: true),
            mode: .normal,
            text: "dangerous input\nProceed? [y/N]",
            significantRuns: [],
            changedRows: [3]
        )
        let surface = TmuxSurface(
            sessionIdentity: TmuxSessionIdentity(
                serverSessionID: "$1",
                createdAtEpoch: 1
            ),
            windowID: "@1",
            paneID: "%1",
            currentCommand: "zsh"
        )
        return TerminalApprovalRequest(
            scope: try TerminalApprovalScope(
                batch: batch,
                endpointID: endpointID,
                screen: screen,
                surface: surface
            ),
            batch: batch,
            reason: "Destructive terminal input"
        )
    }
}
