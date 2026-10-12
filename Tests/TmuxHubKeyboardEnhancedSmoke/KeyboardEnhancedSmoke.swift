import AppKit
@preconcurrency import SwiftTerm

/// Tests enhanced keyboard events against deterministic keyboard-layout data,
/// without posting OS events, changing input sources, or opening a process.
@main
struct KeyboardEnhancedSmoke {
    @MainActor
    static func main() {
        do {
            try run()
            print("Enhanced keyboard smoke passed: shifted identities, alternate layouts, functional keys, composition, and text input.")
        } catch {
            FileHandle.standardError.write(Data("Enhanced keyboard smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = InputTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let recorder = KeyRecorder()
        view.terminalDelegate = recorder
        let terminal = view.getTerminal()

        func check(_ event: LayoutEvent, mode: Int, expected: String, label: String) throws {
            terminal.feed(text: "\u{1b}[=\(mode)u")
            recorder.bytes.removeAll()
            view.keyDown(with: event)
            try require(recorder.bytes == Array(expected.utf8), "\(label), mode=\(mode)")
        }

        for mode in [1, 8] {
            try check(LayoutEvent(keyCode: 44, base: "/", shifted: "?", text: "\u{7f}"),
                      mode: mode, expected: "\u{1b}[47;6u", label: "Ctrl+Shift+/ keeps the slash identity")
            try check(LayoutEvent(keyCode: 19, base: "2", shifted: "@", text: "\u{0}"),
                      mode: mode, expected: "\u{1b}[50;6u", label: "Ctrl+Shift+2 keeps the digit identity")
            try check(LayoutEvent(keyCode: 24, base: "=", shifted: "+", text: "+"),
                      mode: mode, expected: "\u{1b}[61;6u", label: "Ctrl+Shift+= keeps the equals identity")
        }
        for mode in [5, 13, 31] {
            try check(LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "\u{1}"),
                      mode: mode, expected: "\u{1b}[97:65;6u", label: "Shifted alternate excludes Control")
            try check(LayoutEvent(keyCode: 44, base: "/", shifted: "?", text: "\u{7f}"),
                      mode: mode, expected: "\u{1b}[47:63;6u", label: "Shifted punctuation alternate")
            try check(LayoutEvent(keyCode: 19, base: "2", shifted: "@", text: "\u{0}"),
                      mode: mode, expected: "\u{1b}[50:64;6u", label: "Shifted digit alternate excludes NUL")
            // Current-layout primary identity must not be replaced with the
            // US physical-key identity; that belongs in the alternate field.
            try check(LayoutEvent(keyCode: 2, base: "в", shifted: "В", text: "В"),
                      mode: mode, expected: "\u{1b}[1074:1042:100;6u", label: "Non-Latin layout remains primary")
        }

        let unavailableLayout = LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "\u{1}",
                                           translatesLayout: false)
        try check(unavailableLayout, mode: 5, expected: "\u{1b}[97:65;6u",
                  label: "Missing layout translation falls back to event text")
        let capsLock = LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "\u{1}",
                                  modifiers: [.control, .capsLock])
        try check(capsLock, mode: 8, expected: "\u{1b}[97;69u",
                  label: "Caps Lock does not change primary identity")

        // Alternate-key metadata only enriches escape-coded events. It must
        // not turn normal shifted text into a shortcut event on its own.
        let shiftedText: [(UInt16, String, String)] = [
            (0, "a", "A"), (44, "/", "?"), (19, "2", "@"), (2, "в", "В"),
        ]
        for mode in [4, 5] {
            for (keyCode, base, shifted) in shiftedText {
                view.commitText = shifted
                try check(LayoutEvent(keyCode: keyCode, base: base, shifted: shifted,
                                      text: shifted, modifiers: .shift),
                          mode: mode, expected: shifted, label: "Alternate-key mode preserves typed \(shifted)")
            }
        }
        view.commitText = "A"
        try check(LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "A", modifiers: .shift),
                  mode: 8, expected: "\u{1b}[97;2u", label: "Report-all still encodes shifted typing")
        try check(LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "A", modifiers: .shift),
                  mode: 13, expected: "\u{1b}[97:65;2u", label: "Report-all still includes alternate metadata")
        try check(LayoutEvent(keyCode: 0, base: "a", shifted: "A", text: "A", modifiers: .shift),
                  mode: 31, expected: "\u{1b}[97:65;2;65u", label: "Report-all still includes associated text")
        view.commitText = nil
        try check(LayoutEvent(keyCode: 44, base: "/", shifted: "?", text: "\u{7f}"),
                  mode: 4, expected: "\u{1b}[47:63;6u", label: "Non-legacy control combination still uses CSI")

        for mode in [1, 8, 31] {
            try check(LayoutEvent(keyCode: 48, base: "\t", shifted: "\u{19}", text: "\u{19}"),
                      mode: mode, expected: "\u{1b}[9;6u", label: "Ctrl+Shift+Tab is Tab")
            try check(LayoutEvent(keyCode: 36, base: "\r", shifted: "\r", text: "\r",
                                  modifiers: .control),
                      mode: mode, expected: "\u{1b}[13;5u", label: "Control+Return")
            try check(LayoutEvent(keyCode: 51, base: "\u{7f}", shifted: "\u{7f}", text: "\u{8}",
                                  modifiers: .control),
                      mode: mode, expected: "\u{1b}[127;5u", label: "Control+Backspace")
            try check(LayoutEvent(keyCode: 53, base: "\u{1b}", shifted: "\u{1b}", text: "\u{1b}",
                                  modifiers: .control),
                      mode: mode, expected: "\u{1b}[27;5u", label: "Control+Escape")
        }

        terminal.feed(text: "\u{1b}[=8u")
        view.setMarkedText("输入", selectedRange: NSRange(location: 0, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        recorder.bytes.removeAll()
        let previousInterpretations = view.interpretations
        view.keyDown(with: LayoutEvent(keyCode: 36, base: "\r", shifted: "\r", text: "\r", modifiers: []))
        try require(view.interpretations == previousInterpretations + 1 && recorder.bytes.isEmpty,
                    "Composing Return must remain available to the text input system")
        view.unmarkText()

        // Typed text still goes through AppKit's interpretation step. Use an
        // in-memory commit here to avoid involving the current system IME.
        terminal.feed(text: "\u{1b}[=0u")
        view.commitText = "text"
        recorder.bytes.removeAll()
        view.keyDown(with: LayoutEvent(keyCode: 17, base: "t", shifted: "T", text: "t", modifiers: []))
        try require(recorder.bytes == Array("text".utf8), "Default text input is unchanged")
        terminal.feed(text: "\u{1b}[=31u")
        view.optionAsMetaKey = false
        view.commitText = "@"
        recorder.bytes.removeAll()
        view.keyDown(with: LayoutEvent(keyCode: 19, base: "ě", shifted: "2", text: "@", modifiers: .option))
        try require(recorder.bytes == Array("@".utf8), "Option composition must retain its produced text")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

/// The same data AppKit supplies, with controlled translation results for US
/// and non-US layouts. No real keyboard layout or global input state changes.
private final class LayoutEvent: NSEvent {
    let physicalKey: UInt16
    let base: String
    let shifted: String
    let text: String
    let modifiers: NSEvent.ModifierFlags
    let translatesLayout: Bool

    init(keyCode: UInt16, base: String, shifted: String, text: String,
         modifiers: NSEvent.ModifierFlags = [.control, .shift], translatesLayout: Bool = true) {
        physicalKey = keyCode
        self.base = base
        self.shifted = shifted
        self.text = text
        self.modifiers = modifiers
        self.translatesLayout = translatesLayout
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Unused in test") }
    override var type: NSEvent.EventType { .keyDown }
    override var keyCode: UInt16 { physicalKey }
    override var characters: String? { text }
    override var charactersIgnoringModifiers: String? { modifiers.contains(.shift) ? shifted : base }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var isARepeat: Bool { false }
    override func characters(byApplyingModifiers modifiers: NSEvent.ModifierFlags) -> String? {
        guard translatesLayout else { return nil }
        return modifiers.contains(.shift) ? shifted : base
    }
}

@MainActor
private final class InputTerminalView: TerminalView {
    var interpretations = 0
    var commitText: String?
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        interpretations += 1
        if let commitText {
            insertText(commitText, replacementRange: NSRange(location: 0, length: 0))
        }
    }
}

@MainActor
private final class KeyRecorder: @preconcurrency TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
