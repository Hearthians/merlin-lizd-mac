import AppKit
import Combine
import Darwin
import Foundation
import TmuxHubCore
@preconcurrency import SwiftTerm

@MainActor
final class TerminalSession: ObservableObject, Identifiable,
    LocalProcessTerminalViewDelegate
{
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
        case closed
    }

    let id: UUID
    let terminalView: AttachmentTerminalView
    let attachmentModel: TerminalAttachmentModel
    @Published private(set) var linkTransferMessage: String?
    @Published private(set) var isLinkTransferActive = false
    var isSelected = false {
        didSet { if oldValue != isSelected { attachmentModel.noteInteraction() } }
    }
    private var command: CommandSpec?
    private var currentDirectory: String?
    private let attachmentService: AttachmentTransferService
    private let forwardedLinks: ForwardedLinksModel
    private var linkTask: Task<Void, Never>?
    private var savePanel: NSSavePanel?

    @Published private(set) var state: State = .idle
    private(set) var hasStarted = false
    private var didReportExit = false

    init(
        id: UUID = UUID(),
        command: CommandSpec,
        attachmentModel: TerminalAttachmentModel,
        service: AttachmentTransferService,
        forwardedLinks: ForwardedLinksModel,
        currentDirectory: String? = nil
    ) {
        self.id = id
        self.command = command
        self.attachmentModel = attachmentModel
        attachmentService = service
        self.forwardedLinks = forwardedLinks
        self.currentDirectory = currentDirectory
        terminalView = AttachmentTerminalView(frame: .zero)
        terminalView.processDelegate = self
        terminalView.receiveAttachments = { [weak attachmentModel] board, preferImage in
            attachmentModel?.receive(board, preferImage: preferImage) ?? false
        }
        terminalView.hoverChanged = { [weak attachmentModel] in attachmentModel?.isDropTargeted = $0 }
        terminalView.inputChanged = { [weak attachmentModel] in attachmentModel?.noteInteraction() }
        terminalView.openLink = { [weak self] link, _ in self?.open(link: link) }
        terminalView.browseFile = { [weak self] link, _ in self?.open(link: link, browseInSFTP: true) }
        attachmentModel.bind(
            canInsert: { [weak self] in
                guard let self else { return false }
                return self.state == .running && self.isSelected
                    && self.terminalView.window?.isKeyWindow == true
            },
            canAutoInsert: { [weak self] in
                guard let self else { return false }
                return self.terminalView.window?.firstResponder === self.terminalView
            },
            focusTerminal: { [weak self] in
                guard let self, self.isSelected else { return }
                self.terminalView.window?.makeFirstResponder(self.terminalView)
            },
            insert: { [weak self] text in
                guard let self else { return }
                self.terminalView.window?.makeFirstResponder(self.terminalView)
                self.terminalView.pasteText(text)
            },
            localDirectory: { [weak self] in
                self?.localWorkingDirectory()
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
            }
        )
    }

    func startIfNeeded() {
        guard !hasStarted, state != .closed, let command else { return }
        hasStarted = true
        terminalView.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: TerminalProcessEnvironment.inherited(
                overrides: command.environment
            ),
            currentDirectory: currentDirectory
        )
        self.command = nil
        state = .running
    }

    func close() {
        guard state != .closed else { return }
        command = nil
        attachmentModel.noteInteraction()
        linkTask?.cancel()
        linkTask = nil
        savePanel?.cancel(nil)
        savePanel = nil
        let shouldTerminate = state == .running && terminalView.process.running
        let processID = shouldTerminate ? terminalView.process.shellPid : 0
        state = .closed
        if shouldTerminate {
            terminalView.terminate()
            TerminalProcessReaper.reap(processID: processID)
        }
        terminalView.processDelegate = nil
    }

    func dismissLinkTransferMessage() {
        guard !isLinkTransferActive else { return }
        linkTransferMessage = nil
    }

    private func open(link: String, browseInSFTP: Bool = false) {
        guard state == .running, isSelected, linkTask == nil,
            savePanel == nil else { return }
        if let url = URL(string: link), let scheme = url.scheme,
            scheme.lowercased() != "file"
        {
            if let destination = attachmentModel.target.sshDestination,
                let endpoint = LoopbackURL(link)
            {
                openForwarded(
                    endpoint,
                    destination: destination
                )
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        linkTransferMessage = "正在定位文件…"
        isLinkTransferActive = true
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await attachmentService.context(
                    target: attachmentModel.target,
                    sessionName: attachmentModel.sessionName,
                    localDirectory: localWorkingDirectory(),
                    herdrReference: attachmentModel.herdrReference,
                    notificationRoute: attachmentModel.notificationRoute
                )
                let resolvedPath: String
                if browseInSFTP {
                    resolvedPath = try await attachmentService.resolveBrowsePath(link, context: context)
                } else {
                    resolvedPath = try await attachmentService.resolveDownloadPath(link, context: context)
                }
                try Task.checkCancellation()
                guard state == .running, isSelected else { throw CancellationError() }
                switch context.target {
                case .local:
                    linkTask = nil
                    isLinkTransferActive = false
                    linkTransferMessage = nil
                    NSWorkspace.shared.open(URL(fileURLWithPath: resolvedPath))
                case let .ssh(alias):
                    if browseInSFTP {
                        guard context.sshEndpoint == nil else {
                            throw NSError(domain: "TmuxHub.SFTPDownloader", code: 2, userInfo: [
                                NSLocalizedDescriptionKey: "此会话连接到指定登录节点，外部 SFTP Downloader 暂不支持该连接。请直接点击文件链接下载。"
                            ])
                        }
                        let url = try SFTPDownloaderLink.url(host: alias, path: resolvedPath)
                        guard let application = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "local.sftp-downloader"
                        ) else {
                            throw NSError(domain: "TmuxHub.SFTPDownloader", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "未找到 SFTP Downloader，请先安装支持文件位置联动的版本。"
                            ])
                        }
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        _ = try await NSWorkspace.shared.open(
                            [url], withApplicationAt: application, configuration: configuration
                        )
                        linkTask = nil
                        isLinkTransferActive = false
                        linkTransferMessage = nil
                        return
                    }
                    linkTask = nil
                    isLinkTransferActive = false
                    linkTransferMessage = nil
                    presentSavePanel(for: resolvedPath, context: context)
                }
            } catch is CancellationError {
                linkTask = nil
                isLinkTransferActive = false
                linkTransferMessage = nil
            } catch {
                linkTask = nil
                isLinkTransferActive = false
                linkTransferMessage = error.localizedDescription
            }
        }
    }

    private func openForwarded(
        _ endpoint: LoopbackURL,
        destination: String
    ) {
        linkTransferMessage = "正在转发远端端口 \(endpoint.remotePort)…"
        isLinkTransferActive = true
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await forwardedLinks.open(
                    destination: destination,
                    endpoint: endpoint,
                    sshEndpoint: attachmentModel.notificationRoute?.sshEndpoint
                )
                try Task.checkCancellation()
                guard state == .running else {
                    throw CancellationError()
                }
                linkTask = nil
                isLinkTransferActive = false
                linkTransferMessage = nil
                if !NSWorkspace.shared.open(localURL) {
                    linkTransferMessage = "端口转发已建立，但系统浏览器无法打开链接。"
                }
            } catch is CancellationError {
                linkTask = nil
                isLinkTransferActive = false
                linkTransferMessage = nil
            } catch {
                linkTask = nil
                isLinkTransferActive = false
                linkTransferMessage = error.localizedDescription
            }
        }
    }

    private func presentSavePanel(for remotePath: String, context: AttachmentContext) {
        guard state == .running, isSelected, let window = terminalView.window else { return }
        let filename = (remotePath as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            linkTransferMessage = AttachmentError.invalidPath.localizedDescription
            return
        }
        let panel = NSSavePanel()
        savePanel = panel
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = filename
        panel.title = "下载远端文件"
        panel.message = "从 \(attachmentModel.target.sshDestination ?? "远端") 下载：\(remotePath)"
        do {
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
            let defaultDirectory = downloads.appendingPathComponent(
                "_tmuxhub_download",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: defaultDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            panel.directoryURL = defaultDirectory
        } catch {
            savePanel = nil
            linkTransferMessage = "无法创建默认下载目录 ~/Downloads/_tmuxhub_download。"
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.savePanel = nil
                guard response == .OK, let destination = panel.url else { return }
                self.download(remotePath: remotePath, context: context, to: destination)
            }
        }
    }

    private func download(
        remotePath: String,
        context: AttachmentContext,
        to destination: URL
    ) {
        guard linkTask == nil else { return }
        linkTransferMessage = "正在下载 \(destination.lastPathComponent)…"
        isLinkTransferActive = true
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await attachmentService.download(
                    remotePath: remotePath,
                    context: context,
                    destination: destination
                )
                let opened = NSWorkspace.shared.open(destination)
                linkTransferMessage = opened
                    ? "已下载并打开 \(destination.path)"
                    : "已下载到 \(destination.path)，但未找到可打开它的默认应用。"
            } catch is CancellationError {
                linkTransferMessage = "下载已取消。"
            } catch {
                linkTransferMessage = error.localizedDescription
            }
            isLinkTransferActive = false
            linkTask = nil
        }
    }

    private func localWorkingDirectory() -> String {
        LocalProcessDirectory.path(processID: terminalView.process.shellPid)
            ?? currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {}

    nonisolated func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.attachmentModel.target == .local,
                let directory else { return }
            let path = directory.hasPrefix("file:") ? URL(string: directory)?.path : directory
            guard let path, (try? AttachmentPaths.validate(path)) != nil else { return }
            self.currentDirectory = path
        }
    }

    nonisolated func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.state != .closed, !self.didReportExit else {
                return
            }
            self.didReportExit = true
            self.state = .exited(exitCode)
        }
    }
}

private enum TerminalProcessReaper {
    private static let queue = DispatchQueue(
        label: "com.sshtmuxhub.terminal-process-reaper",
        qos: .utility,
        attributes: .concurrent
    )
    private static let gracePeriodNanoseconds: UInt64 = 2_000_000_000

    static func reap(processID: pid_t) {
        guard processID > 0 else { return }
        queue.async {
            var status: Int32 = 0
            let deadline = DispatchTime.now().uptimeNanoseconds
                + gracePeriodNanoseconds
            while true {
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID { return }
                if result == -1 {
                    if errno == EINTR { continue }
                    return
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    _ = kill(processID, SIGKILL)
                    repeat {
                        errno = 0
                    } while waitpid(processID, &status, 0) == -1
                        && errno == EINTR
                    return
                }
                usleep(50_000)
            }
        }
    }
}

private enum TerminalProcessEnvironment {
    static func inherited(overrides: [String: String]) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment.merge(overrides, uniquingKeysWith: { _, override in override })
        return environment.map { "\($0.key)=\($0.value)" }
    }
}
