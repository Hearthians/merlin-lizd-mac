import AppKit
import SwiftUI

struct WindowHeaderDragArea: NSViewRepresentable {
    // The macOS screen-sharing indicator can extend beyond the traffic lights.
    static let leadingControlsInset: CGFloat = 104

    func makeNSView(context: Context) -> NSView {
        WindowHeaderDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowHeaderDragView)?.configureWindow()
    }
}

private final class WindowHeaderDragView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
        }
    }

    func configureWindow() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.toolbar != nil { window.toolbar = nil }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2, let window,
            !window.styleMask.contains(.fullScreen)
        else { return }

        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
        case "minimize":
            window.performMiniaturize(nil)
        case "none":
            break
        case "fill":
            WindowHeaderFillState.toggle(window)
        case nil, "maximize", "zoom":
            window.performZoom(nil)
        default:
            break
        }
    }
}

@MainActor
private final class WindowHeaderFillState: NSObject {
    private static let states = NSMapTable<NSWindow, WindowHeaderFillState>.weakToStrongObjects()
    private var previousFrame: NSRect?
    private var filledFrame: NSRect?

    static func toggle(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let state = states.object(forKey: window) ?? WindowHeaderFillState()
        states.setObject(state, forKey: window)
        if let previousFrame = state.previousFrame,
            let filledFrame = state.filledFrame,
            abs(window.frame.minX - filledFrame.minX) <= 2,
            abs(window.frame.minY - filledFrame.minY) <= 2,
            abs(window.frame.width - filledFrame.width) <= 2,
            abs(window.frame.height - filledFrame.height) <= 2
        {
            window.setFrame(previousFrame, display: true, animate: true)
            states.removeObject(forKey: window)
        } else {
            // Use the available screen area without private AppKit tiling APIs.
            let visibleFrame = screen.visibleFrame
            let size = NSSize(
                width: min(max(visibleFrame.width, window.minSize.width), window.maxSize.width),
                height: min(max(visibleFrame.height, window.minSize.height), window.maxSize.height)
            )
            let target = NSRect(
                x: visibleFrame.minX, y: visibleFrame.maxY - size.height,
                width: size.width, height: size.height
            )
            state.previousFrame = window.frame
            state.filledFrame = target
            window.setFrame(target, display: true, animate: true)
        }
    }
}

private struct RefreshHubActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ToggleHubSidebarActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var refreshHub: (() -> Void)? {
        get { self[RefreshHubActionKey.self] }
        set { self[RefreshHubActionKey.self] = newValue }
    }

    var toggleHubSidebar: (() -> Void)? {
        get { self[ToggleHubSidebarActionKey.self] }
        set { self[ToggleHubSidebarActionKey.self] = newValue }
    }
}

struct WindowChromeCommands: Commands {
    @FocusedValue(\.refreshHub) private var refreshHub
    @FocusedValue(\.toggleHubSidebar) private var toggleHubSidebar

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("显示或隐藏侧边栏", systemImage: "sidebar.left") {
                toggleHubSidebar?()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(toggleHubSidebar == nil)

            Button("刷新", systemImage: "arrow.clockwise") {
                refreshHub?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(refreshHub == nil)
        }
    }
}
