import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SSHMLPConfig {
    var remoteHost: String = "133757"
    var remoteRoot: String = ""
    var meshlabApp: String = "/Applications/Mesh Compare.app"
    var cacheDir: String = "~/Library/Caches/ssh_mlp"
    var jobs: String = "6"
    var normalizeMeshes: Bool = false
}

enum ConfigStore {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ssh_mlp/config")
    }

    static func load() -> SSHMLPConfig {
        var config = SSHMLPConfig()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            save(config)
            return config
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "REMOTE_HOST": config.remoteHost = value
            case "REMOTE_ROOT": config.remoteRoot = value
            case "MESHLAB_APP": config.meshlabApp = value
            case "CACHE_DIR": config.cacheDir = value
            case "JOBS": config.jobs = value
            case "NORMALIZE_MESHES": config.normalizeMeshes = ConfigStore.boolValue(value)
            default: break
            }
        }
        return config
    }

    static func save(_ config: SSHMLPConfig) {
        let text = """
        # ssh_mlp config
        # Remote paths in .mlp files are downloaded through this SSH host alias.
        REMOTE_HOST=\(config.remoteHost)

        # Optional remote root for relative-path fallback.
        REMOTE_ROOT=\(config.remoteRoot)

        # The app that should open the rewritten local .mlp.
        MESHLAB_APP=\(config.meshlabApp)

        # Local cache for downloaded mesh files and rewritten .mlp files.
        CACHE_DIR=\(config.cacheDir)

        # Parallel downloads.
        JOBS=\(config.jobs)

        # Normalize downloaded .ply/.obj meshes into [-1, 1]^3 before opening.
        NORMALIZE_MESHES=\(config.normalizeMeshes ? 1 : 0)
        """

        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    static var cacheURL: URL {
        let config = load()
        let expanded = NSString(string: config.cacheDir).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    static func boolValue(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct ProgressItem: Identifiable {
    let id: String
    var label: String
    var status: String
    var detail: String
    var transferredBytes: Int64
    var totalBytes: Int64
    var speedBytesPerSecond: Double
}

struct BackendEvent: Decodable {
    let event: String
    let key: String?
    let label: String?
    let status: String?
    let detail: String?
    let transferred: Int64?
    let total: Int64?
    let speed: Double?
    let message: String?
    let outputs: [String]?
}

struct CacheUsage {
    var totalBytes: Int64
    var downloadedMeshBytes: Int64
    var normalizedMeshBytes: Int64
    var batchesBytes: Int64
    var projectsBytes: Int64
}

func diskUsageBytes(for url: URL) -> Int64 {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sk", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let fields = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard let first = fields.first, let kib = Int64(String(first)) else { return 0 }
        return kib * 1024
    } catch {
        return 0
    }
}

func loadCacheUsage() -> CacheUsage {
    let cache = ConfigStore.cacheURL
    return CacheUsage(
        totalBytes: diskUsageBytes(for: cache),
        downloadedMeshBytes: diskUsageBytes(for: cache.appendingPathComponent("files")),
        normalizedMeshBytes: diskUsageBytes(for: cache.appendingPathComponent("normalized_v1")),
        batchesBytes: diskUsageBytes(for: cache.appendingPathComponent("batches")),
        projectsBytes: diskUsageBytes(for: cache.appendingPathComponent("projects"))
    )
}

final class ProgressModel: ObservableObject {
    @Published var title: String
    @Published var message = "Preparing"
    @Published var items: [ProgressItem] = []
    @Published var outputs: [String] = []
    @Published var isRunning = true
    @Published var failed = false

    init(projectName: String) {
        title = projectName
    }

    var completedCount: Int {
        items.filter { ["done", "cached", "local", "normalized"].contains($0.status) }.count
    }

    var byteTotal: Int64 {
        items.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
    }

    var byteTransferred: Int64 {
        items.reduce(Int64(0)) { partial, item in
            let transferred = max(item.transferredBytes, 0)
            if ["done", "cached", "local", "normalized"].contains(item.status), item.totalBytes > 0 {
                return partial + item.totalBytes
            }
            return partial + min(transferred, max(item.totalBytes, transferred))
        }
    }

    var activeSpeed: Double {
        items
            .filter { $0.status == "downloading" }
            .reduce(0) { $0 + max($1.speedBytesPerSecond, 0) }
    }

    var progressValue: Double {
        if byteTotal > 0 {
            return min(1.0, max(0, Double(byteTransferred) / Double(byteTotal)))
        }
        guard !items.isEmpty else { return isRunning ? 0.08 : 1.0 }
        return Double(completedCount) / Double(items.count)
    }

    func apply(_ event: BackendEvent) {
        switch event.event {
        case "message":
            if let message = event.message {
                self.message = message
            }
        case "item":
            guard let key = event.key else { return }
            let existing = items.first(where: { $0.id == key })
            let item = ProgressItem(
                id: key,
                label: event.label ?? existing?.label ?? key,
                status: event.status ?? existing?.status ?? "pending",
                detail: event.detail ?? existing?.detail ?? "",
                transferredBytes: event.transferred ?? existing?.transferredBytes ?? 0,
                totalBytes: event.total ?? existing?.totalBytes ?? 0,
                speedBytesPerSecond: event.speed ?? existing?.speedBytesPerSecond ?? 0
            )
            if let index = items.firstIndex(where: { $0.id == key }) {
                items[index] = item
            } else {
                items.append(item)
            }
            if item.status == "error" {
                failed = true
            }
        case "complete":
            outputs = event.outputs ?? []
            isRunning = false
            if !failed {
                message = "Opened in MeshLab"
            }
        case "error":
            failed = true
            isRunning = false
            message = event.message ?? "Failed"
        default:
            break
        }
    }
}

final class RootModel: ObservableObject {
    @Published var activeProgress: ProgressModel?
    @Published var showingConfig = true
}

func appendLog(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    handle.seekToEndOfFile()
    if let data = text.data(using: .utf8) {
        handle.write(data)
    }
    try? handle.close()
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(bytes, 0))
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    if index == 0 {
        return "\(Int(value)) \(units[index])"
    }
    return String(format: "%.1f %@", value, units[index])
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private let rootModel = RootModel()
    private var receivedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(event:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if !self.receivedFiles {
                self.rootModel.showingConfig = true
                self.showMainWindow()
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedFiles = true
        for filename in filenames {
            runBackend(opening: filename)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func handleOpenDocuments(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        receivedFiles = true

        for index in 1...list.numberOfItems {
            guard let item = list.atIndex(index) else { continue }
            if let url = item.fileURLValue {
                runBackend(opening: url.path)
            } else if let string = item.stringValue {
                if let url = URL(string: string), url.isFileURL {
                    runBackend(opening: url.path)
                } else {
                    runBackend(opening: string)
                }
            }
        }
    }

    private func runBackend(opening file: String) {
        let tool = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/ssh_mlp")
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ssh_mlp-launcher.log")
        let model = ProgressModel(projectName: URL(fileURLWithPath: file).lastPathComponent)
        rootModel.activeProgress = model
        rootModel.showingConfig = false
        showMainWindow()

        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = ["--progress-json", file]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            readProgress(from: stdoutPipe.fileHandleForReading, model: model)
            process.terminationHandler = { proc in
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errorText.isEmpty {
                    appendLog(errorText + "\n", to: log)
                }
                DispatchQueue.main.async {
                    model.isRunning = false
                    if proc.terminationStatus != 0 {
                        model.failed = true
                        if !errorText.isEmpty {
                            model.message = errorText
                        } else if !model.failed {
                            model.message = "Failed with exit \(proc.terminationStatus)"
                        }
                    }
                }
            }
        } catch {
            model.failed = true
            model.isRunning = false
            model.message = "\(error)"
        }
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = RootView(root: rootModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ssh_mlp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func readProgress(from handle: FileHandle, model: ProgressModel) {
        DispatchQueue.global(qos: .utility).async {
            var buffer = ""
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    self.handleProgressLine(line, model: model)
                }
            }
            let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                self.handleProgressLine(rest, model: model)
            }
        }
    }

    private func handleProgressLine(_ line: String, model: ProgressModel) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(BackendEvent.self, from: data) else { return }
        DispatchQueue.main.async {
            model.apply(event)
        }
    }

    func showConfigWindow() {
        rootModel.showingConfig = true
        showMainWindow()
    }
}

struct RootView: View {
    @ObservedObject var root: RootModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconMark(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ssh_mlp")
                        .font(.system(size: 17, weight: .semibold))
                    Text("MeshLab project resolver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $root.showingConfig) {
                    Text("Project").tag(false)
                    Text("Settings").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(root.activeProgress == nil)
            }
            .padding(.top, 18)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            Divider()

            Group {
                if root.showingConfig || root.activeProgress == nil {
                    ConfigView()
                } else if let model = root.activeProgress {
                    ProgressPanel(model: model) {
                        root.showingConfig = true
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.65),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct AppIconMark: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

struct ProgressPanel: View {
    @ObservedObject var model: ProgressModel
    var showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                statusIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Text(model.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progressValue)
                    .progressViewStyle(.linear)
                HStack {
                    Text(summaryText)
                    Spacer()
                    Text(speedText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            if model.items.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing project...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.items) { item in
                            progressRow(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Button("Open Cache") {
                    NSWorkspace.shared.open(ConfigStore.cacheURL)
                }
                if let output = model.outputs.first {
                    Button("Show Project") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
                    }
                }
                Spacer()
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(model.failed ? "Failed" : "Done")
                        .font(.caption)
                        .foregroundStyle(model.failed ? .red : .secondary)
                }
            }
        }
        .padding(28)
    }

    private var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(statusColor.opacity(0.14))
            Image(systemName: model.failed ? "exclamationmark.triangle.fill" : (model.isRunning ? "arrow.down.circle.fill" : "checkmark.circle.fill"))
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .frame(width: 52, height: 52)
    }

    private var statusColor: Color {
        if model.failed { return .red }
        if model.isRunning { return .blue }
        return .green
    }

    private var summaryText: String {
        if model.items.isEmpty {
            return model.isRunning ? "Resolving project files" : "No remote downloads needed"
        }
        if model.byteTotal > 0 {
            return "\(formatBytes(model.byteTransferred)) of \(formatBytes(model.byteTotal)) · \(model.completedCount)/\(model.items.count) files"
        }
        return "\(model.completedCount) of \(model.items.count) files ready"
    }

    private var speedText: String {
        guard model.isRunning, model.activeSpeed > 0 else { return "" }
        return "\(formatBytes(Int64(model.activeSpeed)))/s"
    }

    private func progressRow(_ item: ProgressItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(for: item.status))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: item.status))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(rowMetric(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if item.status == "downloading", item.totalBytes > 0 {
                    ProgressView(value: min(1, Double(item.transferredBytes) / Double(item.totalBytes)))
                        .progressViewStyle(.linear)
                } else if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func color(for status: String) -> Color {
        switch status {
        case "done", "cached", "local", "normalized":
            return .green
        case "checking", "downloading", "normalizing", "pending":
            return .blue
        case "error":
            return .red
        default:
            return .secondary
        }
    }

    private func symbol(for status: String) -> String {
        switch status {
        case "done", "cached", "local", "normalized":
            return "checkmark.circle.fill"
        case "downloading":
            return "arrow.down.circle.fill"
        case "normalizing":
            return "cube.transparent.fill"
        case "checking":
            return "magnifyingglass.circle.fill"
        case "error":
            return "xmark.octagon.fill"
        default:
            return "circle"
        }
    }

    private func rowMetric(_ item: ProgressItem) -> String {
        if item.status == "downloading" {
            let speed = item.speedBytesPerSecond > 0 ? "\(formatBytes(Int64(item.speedBytesPerSecond)))/s" : ""
            if item.totalBytes > 0 {
                let bytes = "\(formatBytes(item.transferredBytes)) / \(formatBytes(item.totalBytes))"
                return speed.isEmpty ? bytes : "\(bytes) · \(speed)"
            }
            return speed.isEmpty ? formatBytes(item.transferredBytes) : "\(formatBytes(item.transferredBytes)) · \(speed)"
        }
        if item.totalBytes > 0 {
            return formatBytes(item.totalBytes)
        }
        return item.status
    }
}

struct ConfigView: View {
    @State private var config = ConfigStore.load()
    @State private var status = "Ready"
    @State private var isTesting = false
    @State private var cacheUsage: CacheUsage?
    @State private var isRefreshingCache = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 14) {
                field("SSH Host", text: $config.remoteHost, prompt: "133757 or host alias")
                field("Remote Root", text: $config.remoteRoot, prompt: "/mnt/... optional")
                appField
                Toggle(isOn: $config.normalizeMeshes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Normalize downloaded meshes")
                        Text("Center each downloaded .ply/.obj mesh and fit it inside [-1, 1]^3.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            }

            cacheSection

            HStack(spacing: 10) {
                Button("Test SSH") { testSSH() }
                    .disabled(config.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                Button("Open Cache") { NSWorkspace.shared.open(ConfigStore.cacheURL) }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear {
            refreshCacheUsage()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconMark(size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("ssh_mlp")
                    .font(.system(size: 22, weight: .semibold))
                Text("Resolve remote MeshLab project files over SSH.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open With")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("/Applications/Mesh Compare.app", text: $config.meshlabApp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Choose App") {
                    chooseOpeningApp()
                }
            }
        }
    }

    private var cacheSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cache")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isRefreshingCache {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Refresh") { refreshCacheUsage() }
                        .disabled(isRefreshingCache)
                }

                if let cacheUsage {
                    VStack(spacing: 7) {
                        cacheRow("Total", bytes: cacheUsage.totalBytes)
                        cacheRow("Downloaded meshes", bytes: cacheUsage.downloadedMeshBytes)
                        cacheRow("Normalized meshes", bytes: cacheUsage.normalizedMeshBytes)
                        cacheRow("Batch records", bytes: cacheUsage.batchesBytes)
                        cacheRow("Rewritten projects", bytes: cacheUsage.projectsBytes)
                    }
                } else {
                    Text("Measuring cache...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .groupBoxStyle(.automatic)
    }

    private func cacheRow(_ label: String, bytes: Int64) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes))
                .font(.system(.body, design: .monospaced))
        }
        .font(.caption)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func chooseOpeningApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose app for rewritten .mlp files"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        if panel.runModal() == .OK, let url = panel.url {
            config.meshlabApp = url.path
        }
    }

    private func save() {
        config.remoteHost = config.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = config.remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        config.remoteRoot = trimmedRoot == "/"
            ? trimmedRoot
            : trimmedRoot.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        config.meshlabApp = config.meshlabApp.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !config.remoteHost.isEmpty else {
            status = "SSH host is required."
            return
        }
        guard !config.meshlabApp.isEmpty else {
            status = "Open With app is required."
            return
        }
        ConfigStore.save(config)
        status = "Saved to \(ConfigStore.configURL.path)"
        refreshCacheUsage()
    }

    private func refreshCacheUsage() {
        guard !isRefreshingCache else { return }
        isRefreshingCache = true
        DispatchQueue.global(qos: .utility).async {
            let usage = loadCacheUsage()
            DispatchQueue.main.async {
                cacheUsage = usage
                isRefreshingCache = false
            }
        }
    }

    private func testSSH() {
        let host = config.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            status = "SSH host is required."
            return
        }

        isTesting = true
        status = "Testing \(host)..."
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    isTesting = false
                    status = process.terminationStatus == 0
                        ? "SSH connection OK."
                        : "SSH failed: \(message.isEmpty ? "exit \(process.terminationStatus)" : message)"
                }
            } catch {
                DispatchQueue.main.async {
                    isTesting = false
                    status = "SSH failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

@main
struct SSHMLPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
