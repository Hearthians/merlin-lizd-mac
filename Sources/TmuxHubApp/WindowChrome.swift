import AppKit
import SwiftUI

struct WindowHeaderDragArea: NSViewRepresentable {
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
        window?.performDrag(with: event)
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
