import AppKit
@preconcurrency import SwiftTerm

/// Checks actual terminal-view dispatch without a process or system clipboard.
@main
struct KeyboardSmoke {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = AttachmentTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let recorder = KeyRecorder()
        view.terminalDelegate = recorder
        var failures: [String] = []
        var checked = 0
        func check(_ label: String, _ chars: String, code: UInt16 = 0,
                   flags: NSEvent.ModifierFlags = .control, expected: [UInt8]) {
            recorder.bytes.removeAll()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
            checked += 1
            if recorder.bytes != expected {
                failures.append("\(label): got \(recorder.bytes), expected \(expected)")
            }
        }
        let controls: [(String, UInt8)] = [
            ("/", 31), ("_", 31), ("@", 0), (" ", 0),
            ("2", 0), ("3", 27), ("4", 28), ("5", 29), ("6", 30), ("7", 31), ("8", 127),
            ("?", 127), ("[", 27), ("\\", 28), ("]", 29), ("^", 30), ("~", 30),
            ("0", 48), ("1", 49), ("9", 57),
        ]
        for (key, value) in controls {
            check("Ctrl+\(key)", key, expected: [value])
            check("Ctrl+Option+\(key)", key, flags: [.control, .option], expected: [27, value])
        }
        for codepoint in UInt8(ascii: "a")...UInt8(ascii: "z") {
            let key = String(UnicodeScalar(codepoint))
            let value = codepoint - 96
            check("Ctrl+\(key)", key, expected: [value])
            check("Ctrl+Shift+\(key)", key.uppercased(), flags: [.control, .shift], expected: [value])
            check("Ctrl+Option+\(key)", key, flags: [.control, .option], expected: [27, value])
        }
        for (name, key, code, suffix) in [
            ("Up", NSUpArrowFunctionKey, UInt16(126), "A"),
            ("Down", NSDownArrowFunctionKey, UInt16(125), "B"),
            ("Right", NSRightArrowFunctionKey, UInt16(124), "C"),
            ("Left", NSLeftArrowFunctionKey, UInt16(123), "D"),
            ("Home", NSHomeFunctionKey, UInt16(115), "H"),
            ("End", NSEndFunctionKey, UInt16(119), "F"),
        ] {
            let chars = String(UnicodeScalar(key)!)
            for (flags, modifier): (NSEvent.ModifierFlags, Int) in [
                ([.control, .function], 5), ([.control, .shift, .function], 6),
                ([.control, .option, .function], 7), ([.shift, .function], 2),
            ] {
                check("\(name) modifiers=\(modifier)", chars, code: code, flags: flags,
                      expected: Array("\u{1b}[1;\(modifier)\(suffix)".utf8))
            }
        }
        for (key, code, number) in [
            (NSInsertFunctionKey, UInt16(114), 2), (NSDeleteFunctionKey, UInt16(117), 3),
            (NSPageUpFunctionKey, UInt16(116), 5), (NSPageDownFunctionKey, UInt16(121), 6),
        ] {
            check("Ctrl+navigation \(number)", String(UnicodeScalar(key)!), code: code,
                  flags: [.control, .function], expected: Array("\u{1b}[\(number);5~".utf8))
        }
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let functionNumbers = [15, 17, 18, 19, 20, 21, 23, 24]
        for index in 0..<12 {
            let sequence = index < 4 ? "\u{1b}[1;5\(String("PQRS".dropFirst(index).first!))"
                : "\u{1b}[\(functionNumbers[index - 4]);5~"
            check("Ctrl+F\(index+1)", String(UnicodeScalar(NSF1FunctionKey + index)!),
                  code: functionCodes[index], flags: [.control, .function], expected: Array(sequence.utf8))
        }
        check("Ctrl+Return", "\r", code: 36, expected: [13])
        check("Ctrl+Tab", "\t", code: 48, expected: [9])
        check("Ctrl+Backspace", "\u{7f}", code: 51, expected: [8])
        check("Ctrl+Escape", "\u{1b}", code: 53, expected: [27])
        check("Ctrl+Shift+Tab", "\u{19}", code: 48, flags: [.control, .shift], expected: [27, 91, 90])
        check("Option+Left retains word movement", String(UnicodeScalar(NSLeftArrowFunctionKey)!),
              code: 123, flags: [.option, .function], expected: [27, 98])
        check("Option+x retains Meta", "x", flags: .option, expected: [27, 120])
        view.optionAsMetaKey = false
        check("Option disabled retains Ctrl+/", "/", flags: [.control, .option], expected: [31])
        view.optionAsMetaKey = true
        view.getTerminal().feed(text: "\u{1b}[?1h")
        check("Application cursor Ctrl+Up", String(UnicodeScalar(NSUpArrowFunctionKey)!),
              code: 126, flags: [.control, .function], expected: Array("\u{1b}[1;5A".utf8))
        let composing = CompositionProbe(frame: view.frame)
        let compositionRecorder = KeyRecorder()
        composing.terminalDelegate = compositionRecorder
        composing.setMarkedText("输入", selectedRange: NSRange(location: 0, length: 2),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        let arrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let shiftArrow = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 123)!
        composing.keyDown(with: shiftArrow)
        checked += 1
        if composing.interpretations != 1 || !compositionRecorder.bytes.isEmpty {
            failures.append("Shift+Left must reach the input method while text is marked")
        }
        composing.unmarkText()
        composing.keyDown(with: shiftArrow)
        checked += 1
        if compositionRecorder.bytes != Array("\u{1b}[1;2D".utf8) {
            failures.append("Shift+Left must resume terminal input after composition")
        }
        if !failures.isEmpty {
            print("Keyboard smoke: \(failures.count)/\(checked) checks failed:\n" + failures.joined(separator: "\n"))
            exit(1)
        }
        print("Keyboard smoke passed: \(checked) control, Meta, navigation, and function-key checks.")
    }
}

@MainActor
private final class CompositionProbe: TerminalView {
    var interpretations = 0
    override func interpretKeyEvents(_ eventArray: [NSEvent]) { interpretations += 1 }
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
