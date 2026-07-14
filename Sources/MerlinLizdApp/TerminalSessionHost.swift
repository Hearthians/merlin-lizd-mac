import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

@MainActor
struct TerminalSessionHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        session.startIfNeeded()
        container.show(session.terminalView)
        return container
    }

    func updateNSView(
        _ nsView: TerminalContainerView,
        context: Context
    ) {
        session.startIfNeeded()
        nsView.show(session.terminalView)
    }

    static func dismantleNSView(
        _ nsView: TerminalContainerView,
        coordinator: Void
    ) {
        nsView.hideTerminal()

        // A TerminalSession owns the view and its local process. SwiftUI may
        // dismantle this host while switching tabs, so termination is reserved
        // for the explicit TerminalSession.close() path.
    }
}

@MainActor
final class TerminalContainerView: NSView {
    private weak var displayedTerminal: AgentTerminalView?

    func show(_ terminal: AgentTerminalView) {
        guard displayedTerminal !== terminal else {
            terminal.frame = bounds
            return
        }

        hideTerminal()

        // A terminal view belongs to one visible host at a time. Moving it makes
        // overlapping SwiftUI transitions safe without changing session lifetime.
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        displayedTerminal = terminal
    }

    func hideTerminal() {
        guard let displayedTerminal else {
            return
        }

        if displayedTerminal.superview === self {
            displayedTerminal.removeFromSuperview()
        }
        self.displayedTerminal = nil
    }
}
