import Testing
@testable import MerlinLizdCore

@Suite("Terminal permission", .serialized)
struct TerminalPermissionPolicyTests {
    @Test("normal screens allow only printable text local edits and navigation")
    func allowsFiniteNormalScreenShapes() throws {
        let allowed: [[TerminalInputEvent]] = [
            [],
            [.text("")],
            [.text("rm -rf /tmp/cache && git push")],
            [.text("你好 👩‍💻 e\u{301}")],
            [.key(.character("é"), modifiers: [])],
            [.key(.character("你"), modifiers: [])],
            [.key(.backspace, modifiers: [])],
            [.key(.delete, modifiers: [])],
            [.key(.up, modifiers: [])],
            [.key(.down, modifiers: [])],
            [.key(.left, modifiers: [])],
            [.key(.right, modifiers: [])],
            [.key(.home, modifiers: [])],
            [.key(.end, modifiers: [])],
            [.key(.pageUp, modifiers: [])],
            [.key(.pageDown, modifiers: [])],
            [
                .text("draft"),
                .key(.left, modifiers: []),
                .key(.backspace, modifiers: []),
                .key(.end, modifiers: []),
                .key(.delete, modifiers: []),
            ],
        ]

        for events in allowed {
            let evaluation = try evaluate(events: events)
            #expect(evaluation.decision == .allow)
            #expect(
                evaluation.deterministicRisk
                    == (events.isEmpty ? .observation : .routine)
            )
        }
    }

    @Test("every terminal key category has one explicit normal-screen outcome")
    func classifiesEveryKeyCategory() throws {
        let routineKeys: [TerminalKey] = [
            .character("x"), .backspace, .delete,
            .up, .down, .left, .right, .home, .end, .pageUp, .pageDown,
        ]
        let approvalKeys: [TerminalKey] = [
            .enter, .escape, .tab, .insert,
        ] + (1...12).map(TerminalKey.function)

        for key in routineKeys {
            let evaluation = try evaluate(events: [.key(key, modifiers: [])])
            #expect(evaluation.deterministicRisk == .routine)
            #expect(evaluation.decision == .allow)
        }
        for key in approvalKeys {
            let evaluation = try evaluate(events: [.key(key, modifiers: [])])
            assertRequiresApproval(evaluation, context: "normal key \(key)")
        }
    }

    @Test("screen and keyboard modes preserve the finite structural policy")
    func classifiesEveryScreenMode() throws {
        let modes = [
            TerminalScreenMode(
                isAlternateScreen: false,
                keyboardMode: .normal
            ),
            TerminalScreenMode(
                isAlternateScreen: false,
                keyboardMode: .applicationCursor
            ),
            TerminalScreenMode(
                isAlternateScreen: true,
                keyboardMode: .normal
            ),
            TerminalScreenMode(
                isAlternateScreen: true,
                keyboardMode: .applicationCursor
            ),
        ]

        for mode in modes {
            let screen = terminalTestScreen(mode: mode)
            let empty = try evaluate(events: [], screen: screen)
            #expect(empty.deterministicRisk == .observation)
            #expect(empty.decision == .allow)

            let navigation = try evaluate(
                events: [.key(.left, modifiers: [])],
                screen: screen
            )
            #expect(navigation.deterministicRisk == .routine)
            #expect(navigation.decision == .allow)

            let text = try evaluate(events: [.text("x")], screen: screen)
            if mode.isAlternateScreen {
                assertRequiresApproval(text, context: "alternate text")
            } else {
                #expect(text.deterministicRisk == .routine)
                #expect(text.decision == .allow)
            }

            assertRequiresApproval(
                try evaluate(
                    events: [.key(.enter, modifiers: [])],
                    screen: screen
                ),
                context: "Enter in mode \(mode)"
            )
        }
    }

    @Test("alternate screens allow navigation only")
    func alternateScreensAllowNavigationOnly() throws {
        let alternate = terminalTestScreen(
            mode: TerminalScreenMode(
                isAlternateScreen: true,
                keyboardMode: .applicationCursor
            )
        )
        let navigation: [TerminalKey] = [
            .up, .down, .left, .right, .home, .end, .pageUp, .pageDown,
        ]
        for key in navigation {
            let evaluation = try evaluate(
                events: [.key(key, modifiers: [])],
                screen: alternate
            )
            #expect(evaluation.decision == .allow)
        }

        let actions: [TerminalInputEvent] = [
            .text("y"),
            .text("harmless printable text"),
            .key(.character("Y"), modifiers: []),
            .key(.backspace, modifiers: []),
            .key(.delete, modifiers: []),
            .key(.enter, modifiers: []),
            .key(.escape, modifiers: []),
            .key(.tab, modifiers: []),
            .key(.insert, modifiers: []),
            .key(.function(12), modifiers: []),
        ]
        for event in actions {
            let evaluation = try evaluate(events: [event], screen: alternate)
            assertRequiresApproval(evaluation, context: "alternate event \(event)")
        }
    }

    @Test("CR LF and CRLF are execution boundaries at every text position")
    func classifiesEveryTextSubmissionBoundary() throws {
        let boundaries = ["\r", "\n", "\r\n"]
        var values: [String] = []
        for boundary in boundaries {
            values += [
                boundary,
                boundary + "after",
                "before" + boundary,
                "before" + boundary + "after",
                "one" + boundary + "two" + boundary,
            ]
        }
        values += ["one\r\ntwo\nthree\rfour"]

        for value in values {
            let evaluation = try evaluate(events: [.text(value)])
            assertRequiresApproval(evaluation, context: value.debugDescription)
        }

        let semanticEnter = try evaluate(
            events: [.key(.enter, modifiers: [])]
        )
        assertRequiresApproval(semanticEnter, context: "semantic Enter")
    }

    @Test("text allows only printable grapheme clusters")
    func validatesPrintableTextGraphemes() throws {
        let printable = [
            "", "ASCII 09 !?[]", " ", "é", "e\u{301}", "你好",
            "😀", "👩‍💻", "✈️", "👍🏽", "1️⃣",
        ]
        for value in printable {
            let evaluation = try evaluate(events: [.text(value)])
            #expect(evaluation.deterministicRisk == .routine)
            #expect(evaluation.decision == .allow)
        }

        let nonPrintable = [
            "\u{202E}",
            "\u{200B}",
            "\u{2028}",
            "\u{2029}",
            "\u{0378}",
            "\u{E000}",
            "\u{301}",
            "\u{0903}",
            "\u{20DD}",
            "\u{200D}",
            "\u{FE0F}",
            "\u{00AD}",
            "ن\u{200C}",
            "x\u{2060}",
            "e\u{034F}",
            "字\u{E0100}",
            "safe\u{202E}txt",
            "x\u{200D}",
        ]
        for value in nonPrintable {
            assertDenied(
                try evaluate(events: [.text(value)]),
                context: value.debugDescription
            )
        }
    }

    @Test("raw controls and malformed character keys deny before approval")
    func deniesMalformedInputShapes() throws {
        let forbiddenValues = Array(0x00...0x1F).filter {
            $0 != 0x0A && $0 != 0x0D
        } + [0x7F] + Array(0x80...0x9F)
        let rawControls = forbiddenValues.compactMap(Unicode.Scalar.init)
            .map(String.init) + ["safe\u{1B}unsafe"]
        for value in rawControls {
            assertDenied(try evaluate(events: [.text(value)]), context: value)
        }

        let malformedCharacters = [
            "", "ab", "e\u{301}", "\u{301}", "\u{0378}",
        ] + (forbiddenValues + [0x0A, 0x0D])
            .compactMap(Unicode.Scalar.init)
            .map(String.init)
        for value in malformedCharacters {
            assertDenied(
                try evaluate(events: [
                    .key(.character(value), modifiers: []),
                ]),
                context: value
            )
        }

        for number in [0, 13, Int.max] {
            assertDenied(
                try evaluate(events: [
                    .key(.function(number), modifiers: []),
                ]),
                context: "invalid function key \(number)"
            )
        }
    }

    @Test("every modifier category requires approval or denies if unencodable")
    func classifiesModifierCategories() throws {
        let knownModifiers: [TerminalKeyModifiers] = [
            .shift, .control, .option, .command,
            [.control, .option],
        ]
        let unsupportedModifiers: [TerminalKeyModifiers] = [
            .command, TerminalKeyModifiers(rawValue: 1 << 7),
        ]

        for modifier in knownModifiers where modifier != .command {
            for key in [TerminalKey.left, .function(1)] {
                assertRequiresApproval(
                    try evaluate(events: [
                        .key(key, modifiers: modifier),
                    ]),
                    context: "modified encodable key \(key), \(modifier)"
                )
            }
        }
        for modifier in [
            TerminalKeyModifiers.control,
            .option,
            [.control, .option],
        ] {
            assertRequiresApproval(
                try evaluate(events: [
                    .key(.character("c"), modifiers: modifier),
                ]),
                context: "modified encodable character, \(modifier)"
            )
        }
        assertDenied(
            try evaluate(events: [
                .key(.character("c"), modifiers: .shift),
            ]),
            context: "shifted character must be represented by its scalar"
        )

        for modifier in [
            TerminalKeyModifiers.shift,
            .control,
            [.control, .option],
        ] {
            for key in [TerminalKey.backspace, .enter] {
                assertDenied(
                    try evaluate(events: [
                        .key(key, modifiers: modifier),
                    ]),
                    context: "unencodable modified key \(key), \(modifier)"
                )
            }
        }
        for key in [TerminalKey.backspace, .enter] {
            assertRequiresApproval(
                try evaluate(events: [
                    .key(key, modifiers: .option),
                ]),
                context: "option-prefixed key \(key)"
            )
        }
        for modifier in unsupportedModifiers {
            for key in [TerminalKey.character("c"), .left, .function(1)] {
                assertDenied(
                    try evaluate(events: [
                        .key(key, modifiers: modifier),
                    ]),
                    context: "unsupported modifier \(key), \(modifier)"
                )
            }
        }
    }

    @Test("declared risk is combined with structural risk and exact scope")
    func combinesDeclaredAndStructuralRisk() throws {
        let endpoint = terminalTestEndpoint()
        let screen = terminalTestScreen()
        let declaredBatch = terminalTestBatch(
            events: [.text("plain UTF-8")],
            risk: .high
        )
        let declared = try TerminalPermissionPolicy().evaluate(
            batch: declaredBatch,
            endpointID: endpoint,
            screen: screen
        )
        #expect(declared.deterministicRisk == .routine)
        #expect(declared.effectiveRisk == .high)
        guard case let .requireApproval(request) = declared.decision else {
            Issue.record("declared high risk must require approval")
            return
        }
        #expect(request.batch == declaredBatch)
        #expect(request.scope == (try TerminalApprovalScope(
            batch: declaredBatch,
            endpointID: endpoint,
            screenRevision: screen.revision
        )))

        let structural = try evaluate(
            events: [.key(.enter, modifiers: [])],
            declaredRisk: .observation
        )
        #expect(structural.deterministicRisk == .high)
        #expect(structural.effectiveRisk == .high)
        assertRequiresApproval(structural, context: "structural boundary")
    }

    @Test("stale oversized and unencodable batches deny")
    func deniesInvalidBatchEnvelope() throws {
        let stale = TerminalInputBatch(
            expectedRevision: 6,
            events: [.text("safe")],
            purpose: "stale",
            declaredRisk: .routine
        )
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
        let commandModifier = terminalTestBatch(
            events: [.key(.left, modifiers: .command)]
        )

        for batch in [
            stale, tooManyEvents, tooLongPurpose, tooManyBytes, commandModifier,
        ] {
            let evaluation = try TerminalPermissionPolicy().evaluate(
                batch: batch,
                endpointID: terminalTestEndpoint(),
                screen: terminalTestScreen()
            )
            assertDenied(evaluation, context: batch.purpose)
        }
    }

    @Test("only the finite allow shapes ever return allow")
    func enforcesClosedWorldAllowInvariant() throws {
        let modes = [
            TerminalScreenMode(
                isAlternateScreen: false,
                keyboardMode: .normal
            ),
            TerminalScreenMode(
                isAlternateScreen: false,
                keyboardMode: .applicationCursor
            ),
            TerminalScreenMode(
                isAlternateScreen: true,
                keyboardMode: .normal
            ),
            TerminalScreenMode(
                isAlternateScreen: true,
                keyboardMode: .applicationCursor
            ),
        ]
        let textCases: [(String, Bool)] = [
            ("", true),
            ("printable rm -rf /", true),
            ("é e\u{301} 你好 👩‍💻", true),
            ("submit\r", false),
            ("submit\n", false),
            ("submit\r\n", false),
            ("control\u{85}", false),
            ("bidi\u{202E}", false),
            ("zero-width\u{200B}", false),
            ("line\u{2028}", false),
            ("paragraph\u{2029}", false),
            ("unassigned\u{0378}", false),
            ("private\u{E000}", false),
            ("\u{301}", false),
            ("\u{200D}", false),
        ]
        var keyCases: [(TerminalKey, Bool, Bool)] = [
            (.character("x"), true, false),
            (.character("xy"), false, false),
            (.enter, false, false),
            (.escape, false, false),
            (.backspace, true, false),
            (.tab, false, false),
            (.up, true, true),
            (.down, true, true),
            (.right, true, true),
            (.left, true, true),
            (.home, true, true),
            (.end, true, true),
            (.insert, false, false),
            (.delete, true, false),
            (.pageUp, true, true),
            (.pageDown, true, true),
            (.function(0), false, false),
            (.function(13), false, false),
        ]
        keyCases += (1...12).map { (.function($0), false, false) }

        for mode in modes {
            let screen = terminalTestScreen(mode: mode)
            for (value, normalAllows) in textCases {
                let evaluation = try evaluate(
                    events: [.text(value)],
                    screen: screen
                )
                let expected = !mode.isAlternateScreen && normalAllows
                #expect((evaluation.decision == .allow) == expected)
            }
            for (key, normalAllows, alternateAllows) in keyCases {
                let evaluation = try evaluate(
                    events: [.key(key, modifiers: [])],
                    screen: screen
                )
                let expected = mode.isAlternateScreen
                    ? alternateAllows
                    : normalAllows
                #expect((evaluation.decision == .allow) == expected)
            }
            for rawValue in UInt8.min...UInt8.max {
                let evaluation = try evaluate(
                    events: [
                        .key(
                            .left,
                            modifiers: TerminalKeyModifiers(rawValue: rawValue)
                        ),
                    ],
                    screen: screen
                )
                #expect(
                    (evaluation.decision == .allow) == (rawValue == 0)
                )
            }
        }
    }

    private func evaluate(
        events: [TerminalInputEvent],
        declaredRisk: TerminalRisk = .routine,
        screen: TerminalScreenSnapshot = terminalTestScreen()
    ) throws -> TerminalPermissionEvaluation {
        try TerminalPermissionPolicy().evaluate(
            batch: terminalTestBatch(
                revision: screen.revision,
                events: events,
                risk: declaredRisk
            ),
            endpointID: terminalTestEndpoint(),
            screen: screen
        )
    }

    private func assertRequiresApproval(
        _ evaluation: TerminalPermissionEvaluation,
        context: String
    ) {
        #expect(evaluation.deterministicRisk == .high)
        guard case .requireApproval = evaluation.decision else {
            Issue.record("expected approval for \(context)")
            return
        }
    }

    private func assertDenied(
        _ evaluation: TerminalPermissionEvaluation,
        context: String
    ) {
        guard case .deny = evaluation.decision else {
            Issue.record("expected denial for \(context)")
            return
        }
    }
}
