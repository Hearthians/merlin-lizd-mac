import AppKit
@preconcurrency import SwiftTerm

@MainActor
final class AttachmentTerminalView: LocalProcessTerminalView {
    var receiveAttachments: ((NSPasteboard, Bool) -> Bool)?
    var hoverChanged: ((Bool) -> Void)?
    var inputChanged: (() -> Void)?
    var openLink: ((String, [String: String]) -> Void)?
    private var pendingFileClick: (link: String, location: NSPoint)?
    private var fileClickWasDragged = false

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
        inputChanged?()
        if receiveAttachments?(NSPasteboard.general, false) == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        inputChanged?()
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        pendingFileClick = nil
        inputChanged?()
        super.mouseDown(with: event)
    }

    override func shouldActivateLink(_ link: String, with event: NSEvent) -> Bool {
        // File links are handled only by the complete Cmd + right-click gesture.
        // Let SwiftTerm finish normal selection and mouse reporting on left-up.
        !Self.isFileLink(link) && super.shouldActivateLink(link, with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputChanged?()
        pendingFileClick = nil
        fileClickWasDragged = false
        if event.modifierFlags.contains(.command),
            let match = link(at: event), Self.isFileLink(match.link)
        {
            window?.makeFirstResponder(self)
            pendingFileClick = (match.link, event.locationInWindow)
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
            let match = link(at: event), match.link == pendingFileClick.link
        else { return }
        requestOpenLink(source: self, link: match.link, params: match.params)
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
            pendingFileClick = nil
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
