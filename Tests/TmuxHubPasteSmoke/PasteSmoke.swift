import AppKit
@preconcurrency import SwiftTerm

/// Exercises the text paste path without reading or changing the system
/// clipboard, starting a terminal process, or using a user's editor session.
@main
struct PasteSmoke {
    @MainActor
    static func main() {
        do {
            try run()
            print("Paste UI smoke passed: literal text, bracket negotiation, Kitty flags, composition, and keyboard input.")
        } catch {
            FileHandle.standardError.write(Data("Paste UI smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = AttachmentTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let recorder = PasteRecorder()
        view.terminalDelegate = recorder
        let terminal = view.getTerminal()
        let json = "{\n  \"schemaVersion\": 1,\n  \"label\": \"测试\",\n  \"enabled\": true\n}\n"
        let payloads = [json, "first\r\n\tsecond\n  third\r", "x", ""]
        // Begin with report-all-keys: before this regression was fixed, a
        // non-bracketed paste became ESC [ 0 u and lost its entire payload.
        let keyboardFlags = [8, 24] + (0...31).filter { $0 != 8 && $0 != 24 }

        func expectPaste(_ text: String, bracketed: Bool, context: String) throws {
            recorder.writes.removeAll()
            view.pasteText(text)
            let framed = (bracketed ? "\u{1b}[200~" : "") + text
                + (bracketed ? "\u{1b}[201~" : "")
            try require(recorder.writes.flatMap { $0 } == Array(framed.utf8),
                        "Paste bytes changed (\(context))")
            try require(recorder.writes.count == 1,
                        "Paste must be sent as one input operation (\(context))")
        }

        for flags in keyboardFlags {
            terminal.feed(text: "\u{1b}[=\(flags)u")
            try require(terminal.keyboardEnhancementFlags.rawValue == flags,
                        "Keyboard test mode was not negotiated")
            for bracketed in [false, true] {
                terminal.feed(text: "\u{1b}[?2004\(bracketed ? "h" : "l")")
                for text in payloads {
                    try expectPaste(text, bracketed: bracketed,
                                    context: "flags=\(flags), bracketed=\(bracketed)")
                }
            }
        }

        // Mode changes can arrive across PTY reads. Do not retain a stale
        // frame policy when an application turns bracketed paste off again.
        terminal.feed(text: "\u{1b}[?2004l\u{1b}[?20")
        terminal.feed(text: "04h")
        try expectPaste(json, bracketed: true, context: "split mode enable")
        terminal.feed(text: "\u{1b}[?1049h")
        try expectPaste(json, bracketed: true, context: "alternate screen")
        terminal.feed(text: "\u{1b}[?1049l\u{1b}[?2004l")
        try expectPaste(json, bracketed: false, context: "mode disabled")

        // A paste ends composition, so the next key must not be swallowed by
        // the Kitty encoder's composition filter.
        terminal.feed(text: "\u{1b}[=8u\u{1b}[?2004h")
        view.setMarkedText("待输入", selectedRange: NSRange(location: 0, length: 3),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectPaste(json, bracketed: true, context: "active composition")
        try require(!view.hasMarkedText(), "Paste must clear marked text")
        recorder.writes.removeAll()
        let controlA = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                       modifierFlags: .control, timestamp: 0,
                                       windowNumber: 0, context: nil,
                                       characters: "\u{1}", charactersIgnoringModifiers: "a",
                                       isARepeat: false, keyCode: 0)!
        view.keyDown(with: controlA)
        try require(recorder.writes.flatMap { $0 } == Array("\u{1b}[97;5u".utf8),
                    "Keyboard input must still use the negotiated Kitty protocol after paste")

        terminal.feed(text: "\u{1b}[=0u")
        recorder.writes.removeAll()
        view.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        try require(recorder.writes.flatMap { $0 } == Array("typed".utf8),
                    "Typed input must not acquire paste framing")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

@MainActor
private final class PasteRecorder: @preconcurrency TerminalViewDelegate {
    var writes: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
