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
        terminal.feed(text: "outputs/result.png\r\nhttps://example.com/reference\r\n"
            + "\u{1b}]8;id=fixture;file:///tmp/result.png\u{1b}\\open file\u{1b}]8;;\u{1b}\\")
        var opened: [(String, [String: String])] = []
        view.openLink = { opened.append(($0, $1)) }

        func event(_ type: NSEvent.EventType, row: Int = 0, col: Int = 3,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let pixels = view.cellSizeInPixels(source: terminal)!
            let scale = window.backingScaleFactor
            let local = NSPoint(x: (CGFloat(col) + 0.5) * CGFloat(pixels.width) / scale,
                                y: view.bounds.height - (CGFloat(row) + 0.5) * CGFloat(pixels.height) / scale)
            return NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                                     modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
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
        // SwiftTerm starts its selection on the first drag event and extends
        // it on subsequent movement, as AppKit does during a physical drag.
        view.mouseDragged(with: event(.leftMouseDragged, col: 2))
        view.mouseDragged(with: event(.leftMouseDragged, col: 8))
        view.mouseUp(with: event(.leftMouseUp, col: 8))
        precondition(opened.isEmpty, "Text selection must not activate a file")
        precondition(view.selectedColumnsRange(row: 0, cols: terminal.cols) != nil,
                     "Text selection must still work over file links")

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
        print("Link UI smoke passed: Cmd + right-click only, drag cancellation, text selection, URLs, OSC 8, and tmux mouse reporting.")
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
