import AppKit
import Combine
import CryptoKit
import ImageIO
import TmuxHubCore

enum AttachmentPhase: Equatable {
    case queued, preparing, uploading, ready, inserted, cancelled
    case failed(String)

    var label: String {
        switch self {
        case .queued: "等待中"
        case .preparing: "检查目标目录…"
        case .uploading: "传输中…"
        case .ready: "就绪 · 点击插入"
        case .inserted: "已插入 · 未发送"
        case .cancelled: "已取消"
        case let .failed(message): message
        }
    }
    var active: Bool { self == .queued || self == .preparing || self == .uploading }
}

struct TerminalAttachment: Identifiable {
    let id: UUID
    let source: URL
    let screenshot: Bool
    let byteCount: Int
    let thumbnail: NSImage?
    var directory: String
    var revision: UInt64
    var phase: AttachmentPhase = .queued
    var path: String?
}

/// One queue per tab, independent of reconnecting/replacing its terminal view.
@MainActor
final class TerminalAttachmentModel: ObservableObject {
    @Published private(set) var items: [TerminalAttachment] = []
    @Published var isDropTargeted = false
    @Published var message: String?
    @Published var directoryOverride: String
    let target: TerminalTarget
    var sessionName: String?
    let herdrReference: HerdrTerminalReference?
    var notificationRoute: CodexNotificationRoute? {
        didSet {
            guard notificationRoute != oldValue else { return }
            noteInteraction()
            let nextKey = Self.directoryPreferenceKey(
                target: target, sessionName: sessionName, herdrReference: herdrReference,
                notificationRoute: notificationRoute
            )
            if nextKey != directoryKey {
                directoryKey = nextKey
                directoryOverride = defaults.string(forKey: nextKey) ?? ""
            }
        }
    }

    private let service: AttachmentTransferService
    private let defaults: UserDefaults
    private var directoryKey: String
    private var revision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var workingID: UUID?
    private var closed = false
    private var clipboardSources: Set<URL> = []
    private var filePanel: NSOpenPanel?
    private var canInsert: () -> Bool = { false }
    private var canAutoInsert: () -> Bool = { false }
    private var focusTerminal: () -> Void = {}
    private var insertText: (String) -> Void = { _ in }
    private var localDirectory: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

    init(target: TerminalTarget, sessionName: String?, service: AttachmentTransferService, defaults: UserDefaults = .standard, herdrReference: HerdrTerminalReference? = nil, notificationRoute: CodexNotificationRoute? = nil) {
        self.target = target
        self.sessionName = sessionName
        self.herdrReference = herdrReference
        self.notificationRoute = notificationRoute
        self.service = service
        self.defaults = defaults
        directoryKey = Self.directoryPreferenceKey(target: target, sessionName: sessionName, herdrReference: herdrReference, notificationRoute: notificationRoute)
        directoryOverride = defaults.string(forKey: directoryKey) ?? ""
    }

    private static func directoryPreferenceKey(target: TerminalTarget, sessionName: String?, herdrReference: HerdrTerminalReference? = nil, notificationRoute: CodexNotificationRoute? = nil) -> String {
        let label: String
        if let route = notificationRoute {
            let identity = ["codex-notification", target.sshDestination.map { "ssh:\($0)" } ?? "local",
                            route.hostname, route.socket, route.sessionID,
                            String(route.sessionCreated), String(route.serverPID)]
            label = identity.map { "\($0.utf8.count):\($0)" }.joined()
        } else if let herdrReference {
            // Keep tmux keys unchanged; each Herdr terminal has its own override,
            // even when another workspace currently has keyboard focus.
            label = "\(target.sshDestination ?? "local")/herdr/\(herdrReference.sessionName ?? "default")/\(herdrReference.terminalID)"
        } else {
            label = "\(target.sshDestination ?? "local")/\(sessionName ?? "shell")"
        }
        let hash = SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
        return "attachment-directory-v1-\(hash)"
    }

    static func migrateDirectoryOverride(
        target: TerminalTarget, from oldName: String?, to newName: String?, defaults: UserDefaults
    ) {
        guard oldName != newName else { return }
        let oldKey = directoryPreferenceKey(target: target, sessionName: oldName)
        let newKey = directoryPreferenceKey(target: target, sessionName: newName)
        guard defaults.object(forKey: newKey) == nil,
            let directory = defaults.string(forKey: oldKey) else { return }
        defaults.set(directory, forKey: newKey)
    }

    func bind(canInsert: @escaping () -> Bool, canAutoInsert: @escaping () -> Bool, focusTerminal: @escaping () -> Void = {}, insert: @escaping (String) -> Void, localDirectory: @escaping () -> String) {
        noteInteraction()
        self.canInsert = canInsert
        self.canAutoInsert = canAutoInsert
        self.focusTerminal = focusTerminal
        insertText = insert
        self.localDirectory = localDirectory
    }

    func noteInteraction() { revision &+= 1 }

    func saveDirectory() {
        do {
            if !directoryOverride.isEmpty { try AttachmentPaths.validate(directoryOverride) }
            defaults.set(directoryOverride, forKey: directoryKey)
            message = nil
        } catch { message = error.localizedDescription }
    }

    @discardableResult
    func receive(_ pasteboard: NSPasteboard, preferImage: Bool = false) -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil,
            let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            addFiles(files)
            return true
        }
        // Rich copied text may include a bitmap representation: keep ordinary
        // Cmd-V text behavior unless this is explicitly an image paste/drop.
        if !preferImage, pasteboard.string(forType: .string) != nil { return false }
        guard let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        do {
            guard raw.count <= AttachmentPaths.maximumFileBytes,
                let imageSource = CGImageSourceCreateWithData(raw as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                width.doubleValue > 0, height.doubleValue > 0,
                width.doubleValue * height.doubleValue <= 50_000_000,
                let bitmap = NSBitmapImageRep(data: raw),
                bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 50_000_000,
                let png = bitmap.representation(using: .png, properties: [:]),
                png.count <= AttachmentPaths.maximumFileBytes else { throw AttachmentError.tooLarge }
            let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TmuxHub/clipboard/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("screenshot.png")
            try png.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            clipboardSources.insert(file)
            addFiles([file], screenshot: true)
            if !items.contains(where: { $0.source == file }) { removeClipboardSource(file) }
        } catch { message = error.localizedDescription }
        return true
    }

    func chooseFiles() {
        guard !closed, filePanel == nil else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            Task { @MainActor in
                self?.filePanel = nil
                guard result == .OK else { return }
                self?.focusTerminal()
                self?.addFiles(panel.urls)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func pasteImage() {
        focusTerminal()
        if !receive(.general, preferImage: true) { message = "剪贴板中没有图片或文件。" }
    }

    func addFiles(_ urls: [URL], screenshot: Bool = false) {
        guard !closed else { return }
        guard urls.count <= 32, items.count + urls.count <= 100 else {
            message = "每批最多 32 个附件；请先移除已完成的附件。"
            return
        }
        for file in urls {
            let scope = file.startAccessingSecurityScopedResource()
            defer { if scope { file.stopAccessingSecurityScopedResource() } }
            do {
                let size = try AttachmentPaths.inspectFile(file)
                let preview = ["png", "jpg", "jpeg", "gif", "tiff", "webp"].contains(file.pathExtension.lowercased()) && size < 10 * 1_024 * 1_024
                    ? NSImage(contentsOf: file) : nil
                items.append(TerminalAttachment(
                    id: UUID(), source: file, screenshot: screenshot, byteCount: size,
                    thumbnail: preview, directory: directoryOverride, revision: revision
                ))
            } catch { message = "\(file.lastPathComponent)：\(error.localizedDescription)" }
        }
        startNext()
    }

    func cancel(_ id: UUID) {
        update(id) { $0.phase = .cancelled }
        if workingID == id { worker?.cancel() }
    }

    func retry(_ id: UUID) {
        guard workingID != id else { return }
        let currentRevision = revision
        let directory = directoryOverride
        update(id) { $0.phase = .queued; $0.revision = currentRevision; $0.directory = directory; $0.path = nil }
        startNext()
    }

    func remove(_ id: UUID) {
        guard workingID != id else { cancel(id); return }
        if let source = items.first(where: { $0.id == id })?.source { removeClipboardSource(source) }
        items.removeAll { $0.id == id }
    }

    func insert(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let path = item.path else { return }
        guard canInsert() else { message = "请先选中并连接此标签页，再插入附件。"; return }
        do {
            insertText(try AttachmentPaths.insertionText([path]))
            update(id) { $0.phase = .inserted }
            message = nil
        } catch { message = error.localizedDescription }
    }

    func copyPath(_ id: UUID) {
        guard let path = items.first(where: { $0.id == id })?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func cancelAll() {
        closed = true
        filePanel?.cancel(nil)
        filePanel = nil
        worker?.cancel()
        for index in items.indices where items[index].phase.active { items[index].phase = .cancelled }
        if worker == nil { clearClipboardSources() }
        noteInteraction()
    }

    private func removeClipboardSource(_ file: URL) {
        guard clipboardSources.remove(file) != nil else { return }
        // Only the unique cache directory created by receive(), never a user
        // file or the durable local/remote attachment referenced by the CLI.
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func clearClipboardSources() {
        for source in Array(clipboardSources) { removeClipboardSource(source) }
    }

    private func update(_ id: UUID, _ body: (inout TerminalAttachment) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private func startNext() {
        guard !closed, worker == nil, let item = items.first(where: { $0.phase == .queued }) else { return }
        workingID = item.id
        worker = Task { [weak self] in
            guard let self else { return }
            await process(item)
            worker = nil
            workingID = nil
            if closed { clearClipboardSources() }
            startNext()
        }
    }

    private func process(_ item: TerminalAttachment) async {
        do {
            update(item.id) { $0.phase = .preparing }
            let context = try await service.context(target: target, sessionName: sessionName, localDirectory: localDirectory(), herdrReference: herdrReference, notificationRoute: notificationRoute)
            try Task.checkCancellation()
            update(item.id) { $0.phase = .uploading }
            let path = try await service.transfer(
                file: item.source, screenshot: item.screenshot, context: context, directoryOverride: item.directory
            )
            try Task.checkCancellation()
            update(item.id) { $0.path = path; $0.phase = .ready }
            guard item.revision == revision, canInsert(), canAutoInsert() else { return }
            // Without an Agent session identity Herdr cannot confirm that the
            // same program still owns this terminal. Keep manual insertion.
            guard herdrReference == nil || context.herdrOccupantID != nil else { return }
            // A pane/window switch, shell/agent change, or cwd change during
            // upload leaves the result ready for explicit insertion instead.
            let current = try? await service.context(target: target, sessionName: sessionName, localDirectory: localDirectory(), herdrReference: herdrReference, notificationRoute: notificationRoute)
            guard current == context, item.revision == revision, canInsert(), canAutoInsert(), !Task.isCancelled else { return }
            insert(item.id)
        } catch is CancellationError {
            update(item.id) { $0.phase = .cancelled }
        } catch {
            update(item.id) { $0.phase = .failed(error.localizedDescription) }
        }
    }
}
