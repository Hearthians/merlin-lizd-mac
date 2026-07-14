import Testing
@testable import MerlinLizdCore

@Suite("Terminal permission", .serialized)
struct TerminalPermissionPolicyTests {
    @Test("routine typing and navigation are allowed")
    func allowsRoutineTypingAndNavigation() throws {
        let policy = TerminalPermissionPolicy()
        let screen = terminalTestScreen()
        let batches = [
            terminalTestBatch(events: [.text("echo hello")]),
            terminalTestBatch(events: [.text("echo git push")]),
            terminalTestBatch(events: [.text("printf rm")]),
            terminalTestBatch(events: [
                .key(.left, modifiers: []),
                .key(.right, modifiers: []),
                .key(.enter, modifiers: []),
            ]),
            terminalTestBatch(events: [.text("printf '%s\\n' hello >> log")]),
        ]

        for batch in batches {
            let evaluation = try policy.evaluate(
                batch: batch,
                endpointID: terminalTestEndpoint(),
                screen: screen
            )
            #expect(evaluation.deterministicRisk == .routine)
            #expect(evaluation.effectiveRisk == .routine)
            #expect(evaluation.decision == .allow)
        }
    }

    @Test("destructive commands require approval")
    func escalatesHighRiskSignals() throws {
        let commands = [
            "rm -rf /tmp/cache",
            "cat source > ~/.config/tool/config",
            "diskutil eraseDisk APFS Scratch /dev/disk9",
            "kill -9 1234",
            "tmux kill-session -t training",
            "deploy --force production",
            "git push origin main",
            "passwd",
            "gh auth logout",
        ]

        for command in commands {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: [.text(command)]),
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )

            #expect(evaluation.deterministicRisk == .high)
            #expect(evaluation.effectiveRisk == .high)
            guard case let .requireApproval(request) = evaluation.decision else {
                Issue.record("expected exact allow-once approval request for \(command)")
                continue
            }
            #expect(request.batch.events == [.text(command)])
            #expect(request.scope.endpointID == terminalTestEndpoint())
            #expect(request.scope.screenRevision == 7)
            #expect(!request.reason.isEmpty)
        }
    }

    @Test("shell wrappers and command chains cannot hide high-risk commands")
    func escalatesWrappedAndChainedCommands() throws {
        let commands = [
            "sudo rm -rf /tmp/cache",
            "sudo -u root rm -rf /tmp/cache",
            "/bin/rm -rf /tmp/cache",
            "echo ready && rm -rf /tmp/cache",
            "sudo diskutil eraseDisk APFS Scratch /dev/disk9",
            "command kill -9 1234",
            "sudo git push origin main",
            "sudo passwd",
        ]

        for command in commands {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: [.text(command)]),
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )

            #expect(evaluation.deterministicRisk == .high)
            guard case .requireApproval = evaluation.decision else {
                Issue.record("wrapped high-risk command must require approval: \(command)")
                continue
            }
        }
    }

    @Test("effective risk is the maximum of declared and deterministic risk")
    func takesMaximumRisk() throws {
        let declaredHigh = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [.text("echo safe")],
                risk: .high
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen()
        )
        let deterministicHigh = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [.text("git push origin main")],
                risk: .observation
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen()
        )

        #expect(declaredHigh.deterministicRisk == .routine)
        #expect(declaredHigh.effectiveRisk == .high)
        #expect(deterministicHigh.deterministicRisk == .high)
        #expect(deterministicHigh.effectiveRisk == .high)
    }

    @Test("Enter and Y acceptances inherit destructive prompt risk")
    func escalatesDestructivePromptAcceptance() throws {
        let screen = terminalTestScreen(
            text: "Delete all snapshots permanently? [y/N]"
        )
        let batches = [
            terminalTestBatch(events: [.key(.enter, modifiers: [])]),
            terminalTestBatch(events: [
                .text("Y"),
                .key(.enter, modifiers: []),
            ]),
        ]

        for batch in batches {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: batch,
                endpointID: terminalTestEndpoint(),
                screen: screen
            )
            #expect(evaluation.deterministicRisk == .high)
            guard case .requireApproval = evaluation.decision else {
                Issue.record("destructive prompt acceptance must require approval")
                return
            }
        }
    }

    @Test("unknown confirmation prompts fail closed while passive Enter does not")
    func unknownConfirmationsEscalate() throws {
        let unknown = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [.key(.enter, modifiers: [])]
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(
                text: "Apply the requested changes now? [y/N]"
            )
        )
        let passive = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [.key(.enter, modifiers: [])]
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(text: "Press Enter to continue")
        )

        #expect(unknown.deterministicRisk == .high)
        #expect(passive.deterministicRisk == .routine)
    }

    @Test("oversized or unencodable mutations are denied before approval")
    func deniesInvalidMutationPayloads() throws {
        let tooManyEvents = TerminalInputBatch(
            expectedRevision: 7,
            events: Array(repeating: .key(.left, modifiers: []), count: 257),
            purpose: "navigate",
            declaredRisk: .routine
        )
        let tooLongPurpose = terminalTestBatch(
            purpose: String(repeating: "p", count: 501)
        )
        let tooManyBytes = terminalTestBatch(
            events: [.text(String(repeating: "x", count: 32 * 1024 + 1))]
        )
        let impossible = terminalTestBatch(
            events: [.key(.enter, modifiers: .command)]
        )

        for batch in [tooManyEvents, tooLongPurpose, tooManyBytes, impossible] {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: batch,
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )
            guard case .deny = evaluation.decision else {
                Issue.record("invalid mutation payload must be denied")
                return
            }
        }
    }
}
