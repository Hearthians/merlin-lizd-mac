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
    private var pendingFileClick: (target: FileClickTarget, location: NSPoint)?
    private var fileClickWasDragged = false
    private var pendingBrowseClick: (target: FileClickTarget, location: NSPoint)?
    private var browseClickWasDragged = false
    private var suppressLinkActivation = false
    private var browseTask: Task<Void, Never>?

    private func cancelScheduledBrowse() {
        browseTask?.cancel()
        browseTask = nil
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
        cancelScheduledBrowse()
        pendingFileClick = nil
        pendingBrowseClick = nil
        browseClickWasDragged = false
        inputChanged?()
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            let match = link(at: event), Self.isFileLink(match.link)
        {
            pendingBrowseClick = (FileClickTarget(link: match.link, params: match.params, selection: nil),
                                  event.locationInWindow)
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
        guard pendingBrowseClick != nil else {
            super.mouseDragged(with: event)
            return
        }
        browseClickWasDragged = true
        let reporting = allowMouseReporting
        allowMouseReporting = false
        super.mouseDragged(with: event)
        allowMouseReporting = reporting
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingBrowseClick else {
            super.mouseUp(with: event)
            return
        }
        self.pendingBrowseClick = nil
        // Finish selection cleanup even if the pointer moved to a different URL.
        let reporting = allowMouseReporting
        allowMouseReporting = false
        suppressLinkActivation = true
        super.mouseUp(with: event)
        suppressLinkActivation = false
        allowMouseReporting = reporting
        guard !browseClickWasDragged, !selectionActive, event.clickCount == 1,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            distance(from: pendingBrowseClick.location, to: event.locationInWindow) <= 4,
            let match = link(at: event), match.link == pendingBrowseClick.target.link,
            match.params == pendingBrowseClick.target.params
        else { return }
        // A double-click starts with this same first down/up pair. Give the
        // system click sequence time to finish before opening another app.
        let delay = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
        browseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard let self, !Task.isCancelled, !selectionActive else { return }
            browseTask = nil
            browseFile?(match.link, match.params)
        }
    }

    override func shouldActivateLink(_ link: String, with event: NSEvent) -> Bool {
        !suppressLinkActivation && !Self.isFileLink(link)
            && super.shouldActivateLink(link, with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelScheduledBrowse()
        inputChanged?()
        if pendingBrowseClick != nil { browseClickWasDragged = true }
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
        if selectionActive {
            guard let selection = getSelection() else { return nil }
            // A selection explicitly identifies one path, including paths that
            // a TUI has split across hard rows. Keep spaces inside each part.
            let path = selection.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined()
            // Even an invalid selection owns the gesture: consume both mouse
            // events without falling back to another file or forwarding them.
            return FileClickTarget(link: path, params: [:], selection: selection)
        }
        guard let match = link(at: event), Self.isFileLink(match.link) else { return nil }
        return FileClickTarget(link: match.link, params: match.params, selection: nil)
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
            browseClickWasDragged = true
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
