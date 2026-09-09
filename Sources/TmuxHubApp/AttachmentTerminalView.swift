import AppKit
@preconcurrency import SwiftTerm

@MainActor
final class AttachmentTerminalView: LocalProcessTerminalView {
    var receiveAttachments: ((NSPasteboard, Bool) -> Bool)?
    var hoverChanged: ((Bool) -> Void)?
    var inputChanged: (() -> Void)?
    var openLink: ((String, [String: String]) -> Void)?

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
        inputChanged?()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { inputChanged?() }
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
