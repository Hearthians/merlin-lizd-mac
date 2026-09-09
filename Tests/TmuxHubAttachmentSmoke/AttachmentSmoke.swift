import AppKit
import TmuxHubCore

/// Exercises the actual AppKit queue/clipboard model without a network, the
/// system clipboard, an agent prompt, or the user's preferences.
@main
struct AttachmentSmoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-ui-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "tmuxhub-attachment-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = AttachmentTransferService(sshMasterPool: SSHMasterPool())
        let remoteTarget = TerminalTarget.ssh(destination: "user@10.30.45.144")
        let oldSession = "hub-10.30.45.144"
        let newSession = "hub-10_30_45_144"
        let oldModel = TerminalAttachmentModel(target: remoteTarget, sessionName: oldSession, service: service, defaults: defaults)
        oldModel.directoryOverride = "/home/user/project"
        oldModel.saveDirectory()
        TerminalAttachmentModel.migrateDirectoryOverride(
            target: remoteTarget, from: oldSession, to: newSession, defaults: defaults
        )
        let migratedModel = TerminalAttachmentModel(target: remoteTarget, sessionName: newSession, service: service, defaults: defaults)
        precondition(migratedModel.directoryOverride == "/home/user/project", "Restored tabs must keep their attachment directory")
        migratedModel.directoryOverride = "/home/user/new-project"
        migratedModel.saveDirectory()
        TerminalAttachmentModel.migrateDirectoryOverride(
            target: remoteTarget, from: oldSession, to: newSession, defaults: defaults
        )
        let preservedModel = TerminalAttachmentModel(target: remoteTarget, sessionName: newSession, service: service, defaults: defaults)
        precondition(preservedModel.directoryOverride == "/home/user/new-project", "Migration must not overwrite newer preferences")
        let herdrReference = HerdrTerminalReference(terminalID: "term_first")
        let herdrModel = TerminalAttachmentModel(target: remoteTarget, sessionName: nil, service: service, defaults: defaults, herdrReference: herdrReference)
        herdrModel.directoryOverride = "/home/user/herdr-project"
        herdrModel.saveDirectory()
        let herdrRestored = TerminalAttachmentModel(target: remoteTarget, sessionName: nil, service: service, defaults: defaults, herdrReference: herdrReference)
        precondition(herdrRestored.directoryOverride == "/home/user/herdr-project")
        for reference in [HerdrTerminalReference(terminalID: "term_other"), HerdrTerminalReference(sessionName: "named", terminalID: "term_first")] {
            let other = TerminalAttachmentModel(target: remoteTarget, sessionName: nil, service: service, defaults: defaults, herdrReference: reference)
            precondition(other.directoryOverride.isEmpty, "Herdr terminals and servers must not share directory overrides")
        }
        let remoteShell = TerminalAttachmentModel(target: remoteTarget, sessionName: nil, service: service, defaults: defaults)
        precondition(remoteShell.directoryOverride.isEmpty, "Herdr must not reuse legacy shell preferences")
        let model = TerminalAttachmentModel(target: .local, sessionName: nil, service: service, defaults: defaults)
        defer { model.cancelAll() }
        var inserted: [String] = []
        var selected = true
        var focused = true
        model.bind(canInsert: { selected }, canAutoInsert: { focused }, insert: { inserted.append($0) }, localDirectory: { directory.path })

        board.setString("plain text file:///tmp/example.png", forType: .string)
        precondition(!model.receive(board), "Plain text must retain normal paste behavior")

        let file = directory.appendingPathComponent("local 中文 file.txt")
        try Data("fixture".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        precondition(model.receive(board), "File-URL pasteboard was not accepted")
        try await settle(model)
        precondition(model.items.last?.phase == .inserted)
        let expectedInsertion = try AttachmentPaths.insertionText([file.path])
        precondition(inserted == [expectedInsertion])

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 180, count: 64)
        board.clearContents()
        board.setData(bitmap.representation(using: .tiff, properties: [:])!, forType: .tiff)
        precondition(model.receive(board), "Screenshot pasteboard was not accepted")
        try await settle(model)
        let screenshot = model.items.last!
        precondition(screenshot.source.pathExtension == "png")
        precondition(screenshot.phase == .inserted)
        precondition(screenshot.thumbnail != nil)
        precondition(screenshot.path!.hasPrefix(directory.path + "/.tmuxhub/attachments/"))
        precondition(NSImage(contentsOfFile: screenshot.path!) != nil)

        model.addFiles([file, file])
        model.noteInteraction() // Typing or switching tabs while the queue runs.
        try await settle(model)
        precondition(model.items.suffix(2).allSatisfy { $0.phase == .ready })
        precondition(inserted.count == 2)
        selected = false
        model.insert(model.items.last!.id)
        precondition(inserted.count == 2, "A background tab must not receive input")
        selected = true
        model.insert(model.items.last!.id)
        precondition(inserted.count == 3)

        focused = false
        model.addFiles([file])
        try await settle(model)
        precondition(model.items.last?.phase == .ready)
        precondition(inserted.count == 3, "A text-field focus must suppress automatic insertion")

        model.addFiles([file, file])
        let cancelled = model.items.last!.id
        model.cancel(cancelled)
        try await settle(model)
        precondition(model.items.last?.phase == .cancelled)
        model.retry(cancelled)
        try await settle(model)
        precondition(model.items.last?.phase == .ready)

        model.remove(screenshot.id)
        precondition(!FileManager.default.fileExists(atPath: screenshot.source.path), "Owned clipboard staging should be removed")
        precondition(FileManager.default.fileExists(atPath: screenshot.path!), "Referenced attachment must survive record removal")
        precondition(inserted.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
        print("Attachment UI model smoke checks passed: files, TIFF→PNG, focus/tab guards, cancel/retry, cleanup, no Enter.")
    }

    @MainActor
    private static func settle(_ model: TerminalAttachmentModel) async throws {
        // Allow the post-transfer context check/automatic insertion to finish.
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            if !model.items.contains(where: { $0.phase.active }) {
                try await Task.sleep(for: .milliseconds(50))
                return
            }
        }
        fatalError("Attachment queue failed to settle")
    }
}
