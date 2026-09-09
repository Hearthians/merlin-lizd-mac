import AppKit
@preconcurrency import SwiftTerm

/// Exercises real AppKit display transitions without opening an SSH connection
/// or modifying the user's app, clipboard, or preferences.
@main
struct DisplaySmoke {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screens = NSScreen.screens.sorted { $0.backingScaleFactor > $1.backingScaleFactor }
        guard let highDensity = screens.first,
              let lowDensity = screens.last,
              highDensity.backingScaleFactor != lowDensity.backingScaleFactor else {
            print("Display UI smoke skipped: connect displays with different backing scales.")
            return
        }

        // Choose a real font whose snapped cell width changes across these
        // displays, so retaining Retina metrics cannot accidentally pass.
        let font = stride(from: 10.0, through: 18.0, by: 0.5).compactMap { size -> NSFont? in
            let candidate = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let advance = candidate.advancement(forGlyph: candidate.glyph(withName: "W")).width
            let high = ceil(advance * highDensity.backingScaleFactor) / highDensity.backingScaleFactor
            let low = ceil(advance * lowDensity.backingScaleFactor) / lowDensity.backingScaleFactor
            return abs(high - low) > 0.01 ? candidate : nil
        }.first!

        let (window, terminal) = makeTerminal(on: highDensity, title: "TmuxHub display smoke")
        let (referenceWindow, reference) = makeTerminal(on: lowDensity, title: "TmuxHub display reference")
        defer {
            window.close()
            referenceWindow.close()
        }
        terminal.font = font
        reference.font = font
        terminal.setFrameSize(terminal.frame.size)
        reference.setFrameSize(reference.frame.size)
        pump()
        let originalWidth = cellSize(terminal).width
        let lowWidth = cellSize(reference).width
        try require(abs(originalWidth - lowWidth) > 0.01, "Fixture must produce different cell widths")

        move(window, to: lowDensity)
        try verify(terminal, matches: reference, label: "Retina to external display")

        for size in [NSSize(width: 713, height: 417), NSSize(width: 1723, height: 643)] {
            window.setContentSize(size)
            referenceWindow.setContentSize(size)
            pump()
            try verify(terminal, matches: reference, label: "External resize to \(size)")
        }

        move(window, to: highDensity)
        move(referenceWindow, to: highDensity)
        reference.font = font // Fresh metrics on the new display are the reference.
        reference.setFrameSize(reference.frame.size)
        pump()
        try verify(terminal, matches: reference, label: "External display back to Retina")
        try require(abs(cellSize(terminal).width - originalWidth) < 0.01,
                    "Round trip must restore the original pixel-aligned cell width")

        // App startup creates the terminal before it belongs to an NSWindow.
        // Attaching to a differently scaled window must also refresh metrics.
        move(referenceWindow, to: lowDensity)
        reference.font = font
        reference.setFrameSize(reference.frame.size)
        let detached = LocalProcessTerminalView(frame: .zero)
        detached.font = font
        detached.frame = reference.bounds
        referenceWindow.contentView?.addSubview(detached)
        pump()
        try verify(detached, matches: reference, label: "Initial attachment on external display")
        detached.removeFromSuperview()

        terminal.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        terminal.setFrameSize(terminal.frame.size)
        reference.font = terminal.font
        reference.setFrameSize(reference.frame.size)
        move(window, to: lowDensity)
        try verify(terminal, matches: reference, label: "Default TmuxHub font on external display")

        print("Display UI smoke passed: \(highDensity.backingScaleFactor)x ↔ \(lowDensity.backingScaleFactor)x, fresh/moved cell metrics, terminal grid, cursor alignment, separator rendering, resizing, and initial attachment.")
    }

    @MainActor
    private static func makeTerminal(on screen: NSScreen, title: String) -> (NSWindow, LocalProcessTerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 550),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.autoresizingMask = [.width, .height]
        window.contentView = terminal
        move(window, to: screen)
        return (window, terminal)
    }

    @MainActor
    private static func move(_ window: NSWindow, to screen: NSScreen) {
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        window.orderFront(nil)
        pump()
        precondition(window.backingScaleFactor == screen.backingScaleFactor,
                     "AppKit did not move the test window onto the requested display")
    }

    @MainActor
    private static func cellSize(_ view: LocalProcessTerminalView) -> NSSize {
        let optimal = view.getOptimalFrameSize()
        let scrollerWidth = view.subviews.compactMap { $0 as? NSScroller }
            .filter { !$0.isHidden }.first?.frame.width ?? 0
        return NSSize(width: (optimal.width - scrollerWidth) / CGFloat(view.getTerminal().cols),
                      height: optimal.height / CGFloat(view.getTerminal().rows))
    }

    @MainActor
    private static func verify(_ actual: LocalProcessTerminalView, matches reference: LocalProcessTerminalView,
                               label: String) throws {
        let actualCell = cellSize(actual)
        let referenceCell = cellSize(reference)
        try require(abs(actualCell.width - referenceCell.width) < 0.01
                    && abs(actualCell.height - referenceCell.height) < 0.01,
                    "\(label): cell size \(actualCell) differs from fresh \(referenceCell)")
        try require(actual.getTerminal().cols == reference.getTerminal().cols
                    && actual.getTerminal().rows == reference.getTerminal().rows,
                    "\(label): terminal grid \(actual.getTerminal().cols)×\(actual.getTerminal().rows) differs from fresh \(reference.getTerminal().cols)×\(reference.getTerminal().rows)")
        try require(actual.getOptimalFrameSize().size == reference.getOptimalFrameSize().size,
                    "\(label): optimal terminal frame differs from a fresh view")
        let scale = actual.window!.backingScaleFactor
        try require(abs(actualCell.width * scale - (actualCell.width * scale).rounded()) < 0.01,
                    "\(label): terminal columns fall between physical pixels")

        actual.feed(text: "\u{1b}[2J\u{1b}[HASCII 中文 box │ screenshot.png\u{1b}[3;11H")
        pump()
        let caret = actual.caretFrame
        try require(abs(caret.origin.x - 10 * actualCell.width) < 0.01
                    && abs(caret.origin.y - (actual.frame.height - 3 * actualCell.height)) < 0.01,
                    "\(label): cursor does not match the terminal grid")
        try verifySeparatorPixels(actual, label: label)
        print("PASS \(label): \(actual.getTerminal().cols)×\(actual.getTerminal().rows), cell \(actualCell)")
    }

    @MainActor
    private static func verifySeparatorPixels(_ view: LocalProcessTerminalView, label: String) throws {
        let columns = [27, 100, 200].filter { $0 + 1 < view.getTerminal().cols }
        let cell = cellSize(view)
        var fixture = "\u{1b}[2J\u{1b}[H"
        for (index, column) in columns.enumerated() {
            // A magenta separator followed by a green cell must remain in
            // adjacent columns. Stale 2x metrics make the separator drift
            // rightward into text/background cells on the 1x screen.
            fixture += "\u{1b}[\(index * 2 + 1);\(column + 1)H\u{1b}[38;2;255;0;255m│\u{1b}[0m\u{1b}[48;2;0;255;0m \u{1b}[0m"
        }
        view.feed(text: fixture)
        pump()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "TmuxHubDisplaySmoke", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not capture test terminal drawing"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if ProcessInfo.processInfo.environment["TMUXHUB_DISPLAY_SNAPSHOT"] != nil {
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-display-\(UUID().uuidString).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: snapshot)
            FileHandle.standardError.write(Data("Display smoke snapshot: \(snapshot.path)\n".utf8))
        }
        let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / view.bounds.width
        for (index, column) in columns.enumerated() {
            let topY = Int((CGFloat(index * 2) + 0.5) * cell.height * pixelsPerPoint)
            var magenta: [Int] = []
            var green: [Int] = []
            // NSBitmapImageRep orientation depends on its graphics context.
            // Find the fixture row from either top- or bottom-origin storage.
            for y in [topY, bitmap.pixelsHigh - 1 - topY] where y >= 0 && y < bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    // AppKit color-manages the bitmap for each display, so
                    // classify the dominant channels rather than exact RGB.
                    if color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.5 {
                        magenta.append(x)
                    }
                    if color.greenComponent > 0.8
                        && color.greenComponent > color.redComponent + 0.2
                        && color.greenComponent > color.blueComponent + 0.2 {
                        green.append(x)
                    }
                }
                if !magenta.isEmpty || !green.isEmpty { break }
            }
            let left = CGFloat(column) * cell.width * pixelsPerPoint
            let boundary = CGFloat(column + 1) * cell.width * pixelsPerPoint
            try require(!magenta.isEmpty && !green.isEmpty,
                        "\(label): missing rendered separator fixture at column \(column)")
            try require(CGFloat(magenta.min()!) >= floor(left)
                        && CGFloat(magenta.max()!) < ceil(boundary)
                        && abs(CGFloat(green.min()!) - boundary) < 1.01
                        && magenta.max()! < green.min()!,
                        "\(label): separator overlaps following column \(column + 1) (separator \(magenta), text cell starts \(green.min()!), expected \(boundary))")
        }
    }

    @MainActor
    private static func pump() {
        let end = Date().addingTimeInterval(0.12)
        while Date() < end {
            RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.01)))
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "TmuxHubDisplaySmoke", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
