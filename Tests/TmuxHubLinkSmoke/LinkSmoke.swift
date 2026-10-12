import AppKit
@preconcurrency import SwiftTerm

/// Exercises real mouse dispatch without starting a terminal process,
/// transferring files, opening URLs, or using the system clipboard.
@main
struct LinkSmoke {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = AttachmentTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 440))
        let recorder = MouseRecorder()
        view.terminalDelegate = recorder
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.close() }
        let terminal = view.getTerminal()
        let initialDimensions = terminal.getDims()
        terminal.feed(text: "outputs/result.png\r\nhttps://example.com/reference\r\n"
            + "\u{1b}]8;id=fixture;file:///tmp/result.png\u{1b}\\open file\u{1b}]8;;\u{1b}\\")
        var opened: [(String, [String: String])] = []
        view.openLink = { opened.append(($0, $1)) }

        func event(_ type: NSEvent.EventType, row: Int = 0, col: Int = 3,
                   flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
            let pixels = view.cellSizeInPixels(source: terminal)!
            let scale = window.backingScaleFactor
            let local = NSPoint(x: (CGFloat(col) + 0.5) * CGFloat(pixels.width) / scale,
                                y: view.bounds.height - (CGFloat(row) + 0.5) * CGFloat(pixels.height) / scale)
            return NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                                     modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: clickCount, pressure: 0)!
        }

        func resetTerminal(_ text: String, columns: Int? = nil) {
            view.selectNone()
            terminal.resize(cols: columns ?? initialDimensions.cols, rows: initialDimensions.rows)
            terminal.resetToInitialState()
            terminal.feed(text: text)
            opened.removeAll()
            recorder.sent.removeAll()
        }

        func select(fromRow: Int = 0, fromCol: Int = 0, toRow: Int = 0, toCol: Int,
                    flags: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: event(.leftMouseDown, row: fromRow, col: fromCol, flags: flags))
            view.mouseDragged(with: event(.leftMouseDragged, row: toRow, col: toCol, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, row: toRow, col: toCol, flags: flags))
            precondition(view.selectionActive, "The fixture must create an actual mouse selection")
            precondition(opened.isEmpty, "Selecting text must not activate it")
        }

        func commandRightClick(row: Int = 3, col: Int = 3) {
            view.rightMouseDown(with: event(.rightMouseDown, row: row, col: col, flags: .command))
            view.rightMouseUp(with: event(.rightMouseUp, row: row, col: col, flags: .command))
        }

        precondition(view.link(at: event(.rightMouseDown))?.link == "outputs/result.png")
        for flags: NSEvent.ModifierFlags in [[], .command] {
            view.mouseDown(with: event(.leftMouseDown, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, flags: flags))
            precondition(opened.isEmpty, "Left-click must not activate a file, even with Command")
        }
        for flags: NSEvent.ModifierFlags in [[], .option, .control] {
            view.rightMouseDown(with: event(.rightMouseDown, flags: flags))
            view.rightMouseUp(with: event(.rightMouseUp, flags: flags))
            precondition(opened.isEmpty, "Right-click requires Command to download")
        }

        view.rightMouseDown(with: event(.rightMouseDown, flags: .command))
        precondition(opened.isEmpty, "Download must wait until the click completes")
        view.rightMouseUp(with: event(.rightMouseUp, flags: .command))
        precondition(opened.map(\.0) == ["outputs/result.png"])
        opened.removeAll()

        view.rightMouseDown(with: event(.rightMouseDown, flags: .command))
        view.rightMouseDragged(with: event(.rightMouseDragged, col: 10, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, flags: .command))
        precondition(opened.isEmpty, "Dragging away and back must cancel a file click")
        view.rightMouseDown(with: event(.rightMouseDown, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp))
        precondition(opened.isEmpty, "Releasing Command cancels the gesture")
        view.rightMouseDown(with: event(.rightMouseDown))
        view.rightMouseUp(with: event(.rightMouseUp, flags: .command))
        precondition(opened.isEmpty, "Command is required at both ends of the gesture")
        view.rightMouseDown(with: event(.rightMouseDown, col: 40, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, flags: .command))
        precondition(opened.isEmpty, "The gesture must begin on the link")
        view.rightMouseDown(with: event(.rightMouseDown, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, row: 2, flags: .command))
        precondition(opened.isEmpty, "Releasing on a different link must not download")

        view.mouseDown(with: event(.leftMouseDown, col: 1))
        // Selection must include the press position even when the first drag
        // event has already moved past it.
        view.mouseDragged(with: event(.leftMouseDragged, col: 2))
        view.mouseDragged(with: event(.leftMouseDragged, col: 8))
        view.mouseUp(with: event(.leftMouseUp, col: 8))
        precondition(opened.isEmpty, "Text selection must not activate a file")
        precondition(view.getSelection() == "utputs/",
                     "Text selection over file links must retain its first characters")

        view.mouseDown(with: event(.leftMouseDown, row: 1))
        view.mouseUp(with: event(.leftMouseUp, row: 1))
        precondition(opened.map(\.0) == ["https://example.com/reference"], "Ordinary URLs retain normal clicks")
        opened.removeAll()

        view.mouseDown(with: event(.leftMouseDown, row: 2))
        view.mouseUp(with: event(.leftMouseUp, row: 2))
        precondition(opened.isEmpty, "OSC 8 file links also require the file gesture")
        view.rightMouseDown(with: event(.rightMouseDown, row: 2, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, row: 2, flags: .command))
        precondition(opened.first?.0 == "file:///tmp/result.png")
        precondition(opened.first?.1["id"] == "fixture", "OSC 8 metadata must survive")
        opened.removeAll()

        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        recorder.sent.removeAll()
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        precondition(opened.isEmpty)
        precondition(recorder.sent.count == 2 && recorder.sent[0].hasSuffix("M") && recorder.sent[1].hasSuffix("m"),
                     "Declining a link must preserve the terminal's mouse press/release pair")
        recorder.sent.removeAll()
        view.rightMouseDown(with: event(.rightMouseDown, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, flags: .command))
        precondition(opened.map(\.0) == ["outputs/result.png"])
        precondition(recorder.sent.isEmpty, "File-download gestures must not leak mouse events to tmux")
        opened.removeAll()

        let selectedPath = "outputs/selected.png"
        resetTerminal(selectedPath + "\r\noutputs/pointer.png\r\n")
        select(toCol: selectedPath.count)
        precondition(view.getSelection() == selectedPath)
        precondition(view.link(at: event(.rightMouseDown, row: 1))?.link == "outputs/pointer.png")
        view.rightMouseDown(with: event(.rightMouseDown, row: 1, flags: .command))
        precondition(opened.isEmpty, "Selected paths must wait for the completed gesture")
        view.rightMouseUp(with: event(.rightMouseUp, row: 1, flags: .command))
        precondition(opened.map(\.0) == [selectedPath], "The selection must override a different pointer link")

        for (path, columns) in [
            ("artifact", 8),
            ("outputs/final mesh", 18),
            ("模型/最终 文件", 14),
        ] {
            resetTerminal(path + "\r\n")
            select(toCol: columns)
            precondition(view.getSelection() == path, "Selection must preserve the complete path: \(path)")
            precondition(view.link(at: event(.rightMouseDown, row: 3)) == nil)
            commandRightClick()
            precondition(opened.map(\.0) == [path],
                         "Selected paths must work over blank cells without filename recognition: \(path)")
        }

        let firstFragment = "  outputs/long project/"
        let lastFragment = "    final mesh.ply  "
        resetTerminal(firstFragment + "\r\n" + lastFragment)
        select(toRow: 1, toCol: lastFragment.count)
        precondition(view.getSelection()?.contains("\n") == true,
                     "The fixture must contain a hard newline")
        commandRightClick()
        precondition(opened.map(\.0) == ["outputs/long project/final mesh.ply"],
                     "Hard-wrapped selected paths must join fragments while preserving internal spaces")

        for wrappedPath in ["folder/mesh final.ply", "nested/path/folder/mesh final.ply"] {
            resetTerminal(wrappedPath, columns: 12)
            select(toRow: wrappedPath.count / 12, toCol: wrappedPath.count % 12)
            precondition(view.getSelection() == wrappedPath,
                         "A real filename space at a first or middle soft-wrap edge must survive selection")
            commandRightClick()
            precondition(opened.map(\.0) == [wrappedPath],
                         "A selected soft-wrapped path must retain its original spaces")
        }

        resetTerminal("abc中", columns: 4)
        select(toRow: 1, toCol: 2)
        precondition(view.getSelection() == "abc中",
                     "Wrapping a wide character must not turn the unused cell into a filename space")
        commandRightClick()
        precondition(opened.map(\.0) == ["abc中"],
                     "A selected path must preserve wide characters across narrow terminal wraps")

        resetTerminal(selectedPath + "\r\n")
        select(toCol: selectedPath.count)
        view.rightMouseDown(with: event(.rightMouseDown, row: 3, flags: .command))
        view.rightMouseDragged(with: event(.rightMouseDragged, row: 3, col: 10, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, row: 3, flags: .command))
        precondition(opened.isEmpty, "Dragging away and back must also cancel a selected-path gesture")
        view.rightMouseDown(with: event(.rightMouseDown, row: 3, flags: .command))
        view.rightMouseUp(with: event(.rightMouseUp, row: 3))
        precondition(opened.isEmpty, "Releasing Command must cancel a selected-path gesture")

        let unchangedPointerPath = "outputs/result.png"
        resetTerminal(unchangedPointerPath + "\r\n" + unchangedPointerPath)
        select(toCol: unchangedPointerPath.count)
        view.rightMouseDown(with: event(.rightMouseDown, row: 1, flags: .command))
        view.selectNone()
        view.rightMouseUp(with: event(.rightMouseUp, row: 1, flags: .command))
        precondition(opened.isEmpty,
                     "Clearing selection must cancel even when the pointer matches the old selected path")

        resetTerminal(unchangedPointerPath + "\r\n" + unchangedPointerPath)
        select(toCol: unchangedPointerPath.count)
        view.rightMouseDown(with: event(.rightMouseDown, row: 1, flags: .command))
        terminal.feed(text: "\u{1b}[Houtputs/second.png")
        precondition(view.getSelection() == "outputs/second.png")
        view.rightMouseUp(with: event(.rightMouseUp, row: 1, flags: .command))
        precondition(opened.isEmpty,
                     "Changing selected text must cancel without falling back to the unchanged pointer link")

        resetTerminal(selectedPath + "\r\noutputs/pointer.png")
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        select(toCol: selectedPath.count, flags: .shift)
        commandRightClick(row: 1)
        precondition(opened.map(\.0) == [selectedPath])
        precondition(recorder.sent.isEmpty, "Selected-file gestures must not leak mouse events to tmux")

        for fixture in [
            (text: "https://example.com/reference", fromCol: 0, toCol: 29,
             selected: "https://example.com/reference"),
            (text: "x   x", fromCol: 1, toCol: 4, selected: "   "),
            (text: "", fromCol: 0, toCol: 3, selected: ""),
        ] {
            resetTerminal(fixture.text + "\r\noutputs/pointer.png")
            terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            select(fromCol: fixture.fromCol, toCol: fixture.toCol, flags: .shift)
            precondition(view.getSelection() == fixture.selected)
            commandRightClick(row: 1)
            precondition(opened.isEmpty,
                         "An active non-file or empty selection must never fall back to the pointer link")
            precondition(recorder.sent.isEmpty,
                         "Rejected selected-file gestures must not leak mouse events to tmux")
        }

        resetTerminal("")
        let json = "{\n  \"schemaVersion\": 1,\n  \"enabled\": true\n}"
        terminal.feed(text: json.replacingOccurrences(of: "\n", with: "\r\n"))
        view.selectNone()

        // This is the same text used by copy(), without touching the clipboard.
        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 0))
        precondition(!view.selectionActive, "A plain press must not activate an empty selection")
        view.mouseDragged(with: event(.leftMouseDragged, row: 1, col: 8))
        view.mouseDragged(with: event(.leftMouseDragged, row: 3, col: 1))
        view.mouseUp(with: event(.leftMouseUp, row: 3, col: 1))
        precondition(view.getSelection() == json, "Fast multiline selection must preserve the opening brace and key")

        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 0))
        view.mouseDragged(with: event(.leftMouseDragged, row: 3, col: 1))
        view.mouseUp(with: event(.leftMouseUp, row: 3, col: 1))
        precondition(view.getSelection() == json, "One drag event must select the complete range")

        view.mouseDown(with: event(.leftMouseDown, row: 3, col: 1))
        view.mouseDragged(with: event(.leftMouseDragged, row: 0, col: 0))
        view.mouseUp(with: event(.leftMouseUp, row: 0, col: 0))
        precondition(view.getSelection() == json, "Reverse selection must preserve its pressed endpoint")

        view.mouseDown(with: event(.leftMouseDown, row: 1, col: 3))
        view.mouseDragged(with: event(.leftMouseDragged, row: 1, col: 9))
        view.mouseUp(with: event(.leftMouseUp, row: 1, col: 9))
        precondition(view.getSelection() == "schema")
        view.mouseDown(with: event(.leftMouseDown, row: 1, col: 16, flags: .shift))
        view.mouseUp(with: event(.leftMouseUp, row: 1, col: 16, flags: .shift))
        precondition(view.getSelection() == "schemaVersion", "Shift-click must retain the existing anchor")

        view.mouseDown(with: event(.leftMouseDown, row: 1, col: 6, clickCount: 2))
        precondition(view.getSelection() == "schemaVersion", "Double-click must still select a word")
        view.mouseDragged(with: event(.leftMouseDragged, row: 0, col: 0))
        view.mouseUp(with: event(.leftMouseUp, row: 0, col: 0))
        precondition(view.getSelection() == "{\n  \"schemaVersion", "Word dragging must keep the seed word")

        view.mouseDown(with: event(.leftMouseDown, row: 1, col: 6, clickCount: 3))
        view.mouseUp(with: event(.leftMouseUp, row: 1, col: 6, clickCount: 3))
        precondition(view.getSelection()?.hasPrefix("  \"schemaVersion\": 1,") == true,
                     "Triple-click must still select a line")

        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 0))
        view.mouseUp(with: event(.leftMouseUp, row: 0, col: 0))
        precondition(!view.selectionActive, "A plain click must clear selection")

        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        recorder.sent.removeAll()
        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 0))
        view.mouseDragged(with: event(.leftMouseDragged, row: 3, col: 1))
        view.mouseUp(with: event(.leftMouseUp, row: 3, col: 1))
        precondition(!view.selectionActive && recorder.sent.count == 3,
                     "Remote mouse tracking must not start a local selection")
        recorder.sent.removeAll()
        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 0, flags: .shift))
        view.mouseDragged(with: event(.leftMouseDragged, row: 3, col: 1, flags: .shift))
        view.mouseUp(with: event(.leftMouseUp, row: 3, col: 1, flags: .shift))
        precondition(view.getSelection() == json && recorder.sent.isEmpty,
                     "Shift bypass must retain the complete local selection without reporting mouse events")
        print("Link UI smoke passed: selection-first file gestures, wrapped paths, URLs, OSC 8, tmux mouse reporting, and full-prefix text selection.")
    }
}

@MainActor
private final class MouseRecorder: @preconcurrency TerminalViewDelegate {
    var sent: [String] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(String(decoding: data, as: UTF8.self)) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        (source as? AttachmentTerminalView)?.requestOpenLink(source: source, link: link, params: params)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
