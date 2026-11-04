import AppKit
@preconcurrency import SwiftTerm

@MainActor
final class AttachmentTerminalView: LocalProcessTerminalView {
    var receiveAttachments: ((NSPasteboard, Bool) -> Bool)?
    var hoverChanged: ((Bool) -> Void)?
    var inputChanged: (() -> Void)?
    var openLink: ((String, [String: String]) -> Void)?
    var browseFile: ((String, [String: String]) -> Void)?
    private struct FileClickTarget: Equatable {
        let link: String
        let params: [String: String]
        // The source is part of the gesture: clearing/changing a selection
        // must not switch the pending action to the link under the pointer.
        let selection: String?
    }
    private enum LocalLeftClickAction {
        case open
        case browse(delayForDoubleClick: Bool)
    }
    private struct PendingLocalLeftClick {
        let target: FileClickTarget
        let location: NSPoint
        let requiredModifiers: NSEvent.ModifierFlags
        let action: LocalLeftClickAction
        let seedsSelection: Bool
    }
    private static let gestureModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private var pendingFileClick: (target: FileClickTarget, location: NSPoint)?
    private var fileClickWasDragged = false
    private var pendingLocalLeftClick: PendingLocalLeftClick?
    private var localLeftClickWasDragged = false
    private var suppressLinkActivation = false
    private var browseTask: Task<Void, Never>?

    /// Full-screen applications such as Herdr own ordinary pointer input while
    /// they have enabled xterm mouse tracking.
    private var terminalApplicationOwnsMouse: Bool {
        allowMouseReporting && getTerminal().mouseMode != .off
    }

    private func cancelScheduledBrowse() {
        browseTask?.cancel()
        browseTask = nil
    }

    private func synchronizeLinkHighlightMode() {
        let desired: LinkHighlightMode = terminalApplicationOwnsMouse ? .hoverWithModifier : .hover
        if linkHighlightMode != desired { linkHighlightMode = desired }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        linkHighlightMode = .hover
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        linkHighlightMode = .hover
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func paste(_ sender: Any) {
        cancelScheduledBrowse()
        inputChanged?()
        if receiveAttachments?(NSPasteboard.general, false) == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        cancelScheduledBrowse()
        inputChanged?()
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        synchronizeLinkHighlightMode()
        cancelScheduledBrowse()
        pendingFileClick = nil
        pendingLocalLeftClick = nil
        localLeftClickWasDragged = false
        inputChanged?()
        let modifiers = event.modifierFlags.intersection(Self.gestureModifiers)

        // Command-click is an explicit local gesture in both shells and TUIs.
        // Resolve an existing selection first, then the link under the pointer.
        if modifiers == .command, let target = localLeftClickTarget(at: event)
        {
            pendingLocalLeftClick = PendingLocalLeftClick(
                target: target,
                location: event.locationInWindow,
                requiredModifiers: .command,
                action: Self.isFileLink(target.link) ? .browse(delayForDoubleClick: false) : .open,
                seedsSelection: false
            )
            window?.makeFirstResponder(self)
            return
        }

        // In ordinary shell output a plain path click keeps the existing browse
        // behavior. A mouse-aware application owns the same unmodified click.
        if event.clickCount == 1, !terminalApplicationOwnsMouse, modifiers.isEmpty,
            let match = link(at: event), Self.isFileLink(match.link)
        {
            pendingLocalLeftClick = PendingLocalLeftClick(
                target: FileClickTarget(link: match.link, params: match.params, selection: nil),
                location: event.locationInWindow,
                requiredModifiers: [],
                action: .browse(delayForDoubleClick: true),
                seedsSelection: true
            )
            // Seed normal text selection without leaking a half-click to tmux.
            let reporting = allowMouseReporting
            allowMouseReporting = false
            super.mouseDown(with: event)
            allowMouseReporting = reporting
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        cancelScheduledBrowse()
        guard let pendingLocalLeftClick else {
            super.mouseDragged(with: event)
            return
        }
        localLeftClickWasDragged = true
        if pendingLocalLeftClick.seedsSelection {
            let reporting = allowMouseReporting
            allowMouseReporting = false
            super.mouseDragged(with: event)
            allowMouseReporting = reporting
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingLocalLeftClick else {
            super.mouseUp(with: event)
            return
        }
        self.pendingLocalLeftClick = nil
        if pendingLocalLeftClick.seedsSelection {
            // Finish selection cleanup even if the pointer moved to another link.
            let reporting = allowMouseReporting
            allowMouseReporting = false
            suppressLinkActivation = true
            super.mouseUp(with: event)
            suppressLinkActivation = false
            allowMouseReporting = reporting
        }
        let modifiers = event.modifierFlags.intersection(Self.gestureModifiers)
        guard !localLeftClickWasDragged, event.clickCount == 1,
            modifiers == pendingLocalLeftClick.requiredModifiers,
            distance(from: pendingLocalLeftClick.location, to: event.locationInWindow) <= 4,
            let target = completedLocalLeftClickTarget(at: event, pending: pendingLocalLeftClick),
            target == pendingLocalLeftClick.target, !target.link.isEmpty
        else { return }

        switch pendingLocalLeftClick.action {
        case .open:
            requestOpenLink(source: self, link: target.link, params: target.params)
        case let .browse(delayForDoubleClick):
            guard !pendingLocalLeftClick.seedsSelection || !selectionActive else { return }
            if delayForDoubleClick {
                // A double-click starts with this same first pair. Wait long
                // enough for the second press to cancel the browse operation.
                let delay = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
                browseTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                    guard let self, !Task.isCancelled, !selectionActive else { return }
                    browseTask = nil
                    browseFile?(target.link, target.params)
                }
            } else {
                browseFile?(target.link, target.params)
            }
        }
    }

    override func shouldActivateLink(_ link: String, with event: NSEvent) -> Bool {
        guard !suppressLinkActivation, !Self.isFileLink(link) else { return false }
        // In a TUI, only a Command-click recognized on mouse-down is local.
        // Every other complete gesture remains owned by the terminal app.
        guard !terminalApplicationOwnsMouse else { return false }
        return super.shouldActivateLink(link, with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        synchronizeLinkHighlightMode()
        super.mouseMoved(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        synchronizeLinkHighlightMode()
        super.flagsChanged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelScheduledBrowse()
        inputChanged?()
        if pendingLocalLeftClick != nil { localLeftClickWasDragged = true }
        pendingFileClick = nil
        fileClickWasDragged = false
        if event.modifierFlags.contains(.command),
            let target = fileClickTarget(at: event)
        {
            window?.makeFirstResponder(self)
            pendingFileClick = (target, event.locationInWindow)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let pendingFileClick else {
            super.rightMouseDragged(with: event)
            return
        }
        if distance(from: pendingFileClick.location, to: event.locationInWindow) > 4 {
            fileClickWasDragged = true
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let pendingFileClick else {
            super.rightMouseUp(with: event)
            return
        }
        self.pendingFileClick = nil
        guard !fileClickWasDragged, event.modifierFlags.contains(.command),
            distance(from: pendingFileClick.location, to: event.locationInWindow) <= 4,
            let target = fileClickTarget(at: event), target == pendingFileClick.target,
            !target.link.isEmpty, Self.isFileLink(target.link)
        else { return }
        requestOpenLink(source: self, link: target.link, params: target.params)
    }

    private func fileClickTarget(at event: NSEvent) -> FileClickTarget? {
        if let selected = selectedClickTarget() { return selected }
        guard let match = link(at: event), Self.isFileLink(match.link) else { return nil }
        return FileClickTarget(link: match.link, params: match.params, selection: nil)
    }

    private func localLeftClickTarget(at event: NSEvent) -> FileClickTarget? {
        if let selected = selectedClickTarget() { return selected }
        guard let match = link(at: event) else { return nil }
        return FileClickTarget(link: match.link, params: match.params, selection: nil)
    }

    private func completedLocalLeftClickTarget(
        at event: NSEvent,
        pending: PendingLocalLeftClick
    ) -> FileClickTarget? {
        if pending.target.selection != nil { return selectedClickTarget() }
        guard let match = link(at: event) else { return nil }
        return FileClickTarget(link: match.link, params: match.params, selection: nil)
    }

    private func selectedClickTarget() -> FileClickTarget? {
        guard selectionActive, let selection = getSelection() else { return nil }
        // A selection explicitly identifies one target, including paths split
        // across terminal rows. Keep spaces inside each selected fragment.
        let target = selection.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        // Even an empty/invalid selection owns the local gesture and prevents
        // fallback to an unrelated pointer link.
        return FileClickTarget(link: target, params: [:], selection: selection)
    }

    private static func isFileLink(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme else { return true }
        return scheme.lowercased() == "file"
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            cancelScheduledBrowse()
            pendingFileClick = nil
            // The press was not sent to tmux; consume its release even after
            // focus changes, while preventing the pending browse action.
            localLeftClickWasDragged = true
            inputChanged?()
        }
        return resigned
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
        hoverChanged?(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hoverChanged?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hoverChanged?(false)
        window?.makeFirstResponder(self)
        return receiveAttachments?(sender.draggingPasteboard, true) ?? false
    }

    override func requestOpenLink(
        source: TerminalView,
        link: String,
        params: [String: String]
    ) {
        if let openLink {
            openLink(link, params)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}
