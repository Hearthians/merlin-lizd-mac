import Testing
@testable import MerlinLizdCore

@Suite("Terminal input")
struct TerminalInputTests {
    @Test("encodes cursor arrows for normal and application modes")
    func encodesCursorArrowsByKeyboardMode() throws {
        let arrows: [TerminalInputEvent] = [
            .key(.up, modifiers: []),
            .key(.down, modifiers: []),
            .key(.right, modifiers: []),
            .key(.left, modifiers: []),
        ]

        #expect(
            try TerminalInputEncoder.encode(
                events: arrows,
                keyboardMode: .normal
            ).elementsEqual("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)
        )
        #expect(
            try TerminalInputEncoder.encode(
                events: arrows,
                keyboardMode: .applicationCursor
            ).elementsEqual("\u{1B}OA\u{1B}OB\u{1B}OC\u{1B}OD".utf8)
        )
    }

    @Test("encodes enter escape navigation and function keys")
    func encodesSpecialKeys() throws {
        let events: [TerminalInputEvent] = [
            .key(.enter, modifiers: []),
            .key(.escape, modifiers: []),
            .key(.home, modifiers: []),
            .key(.end, modifiers: []),
            .key(.insert, modifiers: []),
            .key(.delete, modifiers: []),
            .key(.pageUp, modifiers: []),
            .key(.pageDown, modifiers: []),
            .key(.function(1), modifiers: []),
            .key(.function(4), modifiers: []),
            .key(.function(5), modifiers: []),
            .key(.function(12), modifiers: []),
        ]

        let encoded = try TerminalInputEncoder.encode(
            events: events,
            keyboardMode: .normal
        )

        let expected = "\r\u{1B}\u{1B}[H\u{1B}[F\u{1B}[2~\u{1B}[3~"
            + "\u{1B}[5~\u{1B}[6~\u{1B}OP\u{1B}OS"
            + "\u{1B}[15~\u{1B}[24~"
        #expect(encoded.elementsEqual(expected.utf8))
    }

    @Test("encodes control letters and option as an escape prefix")
    func encodesControlAndOptionCombinations() throws {
        let encoded = try TerminalInputEncoder.encode(
            events: [
                .key(.character("c"), modifiers: .control),
                .key(.character("Z"), modifiers: .control),
                .key(.character("x"), modifiers: .option),
                .key(
                    .character("d"),
                    modifiers: [.control, .option]
                ),
                .key(.right, modifiers: .control),
            ],
            keyboardMode: .normal
        )

        #expect(
            [UInt8](encoded) == [
                0x03,
                0x1A,
                0x1B, 0x78,
                0x1B, 0x04,
                0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43,
            ]
        )
    }

    @Test("rejects modifier and key combinations without an xterm encoding")
    func rejectsImpossibleCombinations() {
        #expect(
            throws: TerminalInputEncodingError.invalidControlCharacter("1")
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.character("1"), modifiers: .control)],
                keyboardMode: .normal
            )
        }
        #expect(
            throws: TerminalInputEncodingError.invalidCharacterKey("ab")
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.character("ab"), modifiers: [])],
                keyboardMode: .normal
            )
        }
        #expect(
            throws: TerminalInputEncodingError.unsupportedModifiers(
                key: .enter,
                modifiers: .control
            )
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.enter, modifiers: .control)],
                keyboardMode: .normal
            )
        }
        #expect(
            throws: TerminalInputEncodingError.unsupportedModifiers(
                key: .character("x"),
                modifiers: .shift
            )
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.character("x"), modifiers: .shift)],
                keyboardMode: .normal
            )
        }
        #expect(throws: TerminalInputEncodingError.invalidFunctionKey(13)) {
            try TerminalInputEncoder.encode(
                events: [.key(.function(13), modifiers: [])],
                keyboardMode: .normal
            )
        }
        #expect(
            throws: TerminalInputEncodingError.unsupportedModifiers(
                key: .left,
                modifiers: .command
            )
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.left, modifiers: .command)],
                keyboardMode: .normal
            )
        }
        let unknown = TerminalKeyModifiers(rawValue: 1 << 7)
        #expect(
            throws: TerminalInputEncodingError.unsupportedModifiers(
                key: .right,
                modifiers: unknown
            )
        ) {
            try TerminalInputEncoder.encode(
                events: [.key(.right, modifiers: unknown)],
                keyboardMode: .normal
            )
        }
    }

    @Test("passes UTF-8 text without terminal reinterpretation")
    func passesUTF8Text() throws {
        let text = "echo 你好 👋🏽\n"

        let encoded = try TerminalInputEncoder.encode(
            events: [.text(text)],
            keyboardMode: .applicationCursor
        )

        #expect(encoded.elementsEqual(text.utf8))
    }
}
