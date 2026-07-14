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

    @Test("reconstructs split typing and the final Enter from the visible editable line")
    func reconstructsEffectiveCommandAcrossBatches() throws {
        let policy = TerminalPermissionPolicy()
        let endpoint = terminalTestEndpoint()
        let first = try policy.evaluate(
            batch: terminalTestBatch(events: [.text("r")]),
            endpointID: endpoint,
            screen: terminalTestScreen()
        )
        let second = try policy.evaluate(
            batch: terminalTestBatch(events: [.text("m -rf /tmp/cache")]),
            endpointID: endpoint,
            screen: terminalTestScreen(
                text: "$ r",
                cursorColumn: 3
            )
        )
        let submitted = try policy.evaluate(
            batch: terminalTestBatch(events: [.key(.enter, modifiers: [])]),
            endpointID: endpoint,
            screen: terminalTestScreen(
                text: "$ rm -rf /tmp/cache",
                cursorColumn: 19
            )
        )

        #expect(first.deterministicRisk == .routine)
        #expect(second.deterministicRisk == .high)
        #expect(submitted.deterministicRisk == .high)
    }

    @Test("applies cursor navigation Backspace and Delete before classification")
    func reconstructsSameBatchEditing() throws {
        let backspace = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [.key(.backspace, modifiers: [])]
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(
                text: "$ rXm -rf /tmp/cache",
                cursorColumn: 4
            )
        )
        let delete = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                events: [
                    .key(.left, modifiers: []),
                    .key(.delete, modifiers: []),
                ]
            ),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(
                text: "$ rmx -rf /tmp/cache",
                cursorColumn: 5
            )
        )

        #expect(backspace.deterministicRisk == .high)
        #expect(delete.deterministicRisk == .high)
    }

    @Test("denies command input when the visible editable line cannot be reconstructed")
    func failsClosedOnUnknownEditableSurface() throws {
        let evaluation = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(events: [.text("rm -rf /tmp/cache")]),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(
                text: "unstructured terminal content",
                cursorColumn: 8
            )
        )

        guard case .deny = evaluation.decision else {
            Issue.record("unknown editable surface must deny mutation")
            return
        }
    }

    @Test("denies control bytes hidden inside text events")
    func rejectsRawTextEditingControls() throws {
        let controls = ["\u{7F}", "\t", "\u{1B}[D"]

        for control in controls {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: [.text(control)]),
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen(
                    text: "$ rXm -rf /tmp/cache",
                    cursorColumn: 4
                )
            )
            guard case .deny = evaluation.decision else {
                Issue.record("raw text control must fail closed")
                continue
            }
        }
    }

    @Test("shell evaluation wrappers and option-prefixed subcommands escalate")
    func escalatesAmbiguousShellEvaluation() throws {
        let commands = [
            "bash -c 'rm -rf /tmp/cache'",
            "echo $(rm -rf /tmp/cache)",
            "echo `rm -rf /tmp/cache`",
            "'rm' -rf /tmp/cache",
            "TARGET=/tmp rm -rf /tmp/cache",
            "bash -lc 'rm -rf /tmp/cache'",
            "eval 'rm -rf /tmp/cache'",
            "if true; then rm -rf /tmp/cache; fi",
            "git -C repo push origin main",
            "git --unknown-option push origin main",
            "tmux -L private kill-session -t training",
            "tmux --unknown-option kill-session -t training",
        ]

        for command in commands {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: [.text(command)]),
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )
            #expect(evaluation.deterministicRisk == .high)
            guard case .requireApproval = evaluation.decision else {
                Issue.record("ambiguous or destructive shell input must escalate: \(command)")
                continue
            }
        }
    }

    @Test("proven quoted text descriptor duplication and benign force options stay routine")
    func avoidsProvableShellFalsePositives() throws {
        let commands = [
            "echo 'git push'",
            "echo '>'",
            "printf '2>&1'",
            "tool 2>&1",
            "sudo echo rm",
            "tail -f log.txt",
            "grep -f patterns.txt input.txt",
        ]

        for command in commands {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: [.text(command)]),
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )
            #expect(evaluation.deterministicRisk == .routine)
            #expect(evaluation.decision == .allow)
        }
    }

    @Test("destructive and unknown action evidence overrides passive prompt text")
    func escalatesMixedAndUnknownPrompts() throws {
        let screens = [
            "Press Enter to continue\nDelete all data permanently? [y/N]",
            "Apply the selected migration now? [OK] [Cancel]",
            "Perform the selected action now?",
        ]
        let affirmatives: [[TerminalInputEvent]] = [
            [.key(.enter, modifiers: [])],
            [.text("OK"), .key(.enter, modifiers: [])],
        ]

        for text in screens {
            for events in affirmatives {
                let evaluation = try TerminalPermissionPolicy().evaluate(
                    batch: terminalTestBatch(events: events),
                    endpointID: terminalTestEndpoint(),
                    screen: terminalTestScreen(text: text)
                )
                #expect(evaluation.deterministicRisk == .high)
            }
        }

        let promptContainingShellMarker = "Delete $ all data permanently? [y/N]"
        let markerEvaluation = try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(events: [.key(.enter, modifiers: [])]),
            endpointID: terminalTestEndpoint(),
            screen: terminalTestScreen(
                text: promptContainingShellMarker,
                cursorColumn: promptContainingShellMarker.count
            )
        )
        #expect(markerEvaluation.deterministicRisk == .high)
    }

    @Test("negative or cancel input does not approve a destructive prompt")
    func permitsNegativePromptResponses() throws {
        let screen = terminalTestScreen(
            text: "Delete all data permanently? [OK] [Cancel]"
        )
        let responses: [[TerminalInputEvent]] = [
            [.text("n"), .key(.enter, modifiers: [])],
            [.text("no"), .key(.enter, modifiers: [])],
            [.key(.escape, modifiers: [])],
        ]

        for events in responses {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: terminalTestBatch(events: events),
                endpointID: terminalTestEndpoint(),
                screen: screen
            )
            #expect(evaluation.deterministicRisk == .routine)
            #expect(evaluation.decision == .allow)
        }
    }
}
