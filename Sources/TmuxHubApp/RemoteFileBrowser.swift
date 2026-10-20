import AppKit
import SwiftUI
import TmuxHubCore

@MainActor
final class RemoteFileBrowserModel: ObservableObject {
    struct Download: Identifiable {
        let id = UUID()
        let entry: RemoteFileEntry
        let destination: URL
        let preview: Bool
        var state = "等待中"
        var finished = false
        var succeeded = false
    }
    @Published var path = "~"
    @Published var entries: [RemoteFileEntry] = []
    @Published var selection: String?
    @Published var filter = ""
    @Published var showHidden = false
    @Published var loading = false
    @Published var error: String?
    @Published var downloads: [Download] = []
    @Published var pins: [String]
    @Published private(set) var history: [String] = []
    let alias: String
    private let service: RemoteFileService
    private var browseTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var activeID: UUID?
    private var requestID = UUID()
    private var currentPath: String?
    private var pinKey: String { "remote-files-pins-" + alias }

    init(alias: String, service: RemoteFileService) {
        self.alias = alias
        self.service = service
        pins = UserDefaults.standard.stringArray(forKey: "remote-files-pins-" + alias) ?? []
        path = UserDefaults.standard.string(forKey: "remote-files-path-" + alias) ?? "~"
    }

    var visibleEntries: [RemoteFileEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) &&
            (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func browse(_ requested: String, remember: Bool = true) {
        browseTask?.cancel()
        let token = UUID()
        requestID = token
        let previous = currentPath
        loading = true
        error = nil
        browseTask = Task {
            do {
                let listing = try await service.list(alias: alias, path: requested)
                guard !Task.isCancelled, requestID == token else { return }
                if remember, let previous, previous != listing.path { history.append(previous) }
                path = listing.path
                currentPath = listing.path
                entries = listing.entries
                selection = nil
                UserDefaults.standard.set(path, forKey: "remote-files-path-" + alias)
            } catch {
                if !Task.isCancelled, requestID == token { self.error = error.localizedDescription }
            }
            if requestID == token { loading = false }
        }
    }

    func back() {
        guard let previous = history.popLast() else { return }
        browse(previous, remember: false)
    }

    func togglePin() {
        if pins.contains(path) { pins.removeAll { $0 == path } } else { pins.append(path) }
        UserDefaults.standard.set(pins, forKey: pinKey)
    }

    func download(_ entry: RemoteFileEntry, preview: Bool = false) {
        guard entry.isDirectory || entry.isFile else { return }
        let destination: URL
        if preview {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("tmuxhub-file-preview", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { self.error = error.localizedDescription; return }
            destination = folder.appendingPathComponent(entry.name)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "下载到此目录"
            panel.message = "选择保存位置：" + entry.name + "（不覆盖同名项目）"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            destination = folder.appendingPathComponent(entry.name)
        }
        downloads.append(Download(entry: entry, destination: destination, preview: preview))
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), !downloads[index].finished else { return }
        if activeID == id { transferTask?.cancel() }
        else { downloads[index].state = "已取消"; downloads[index].finished = true }
    }

    func retry(_ id: UUID) {
        guard let item = downloads.first(where: { $0.id == id }), item.finished, !item.succeeded else { return }
        downloads.append(Download(entry: item.entry, destination: item.destination, preview: item.preview))
        startNext()
    }

    func stop() {
        browseTask?.cancel()
        transferTask?.cancel()
        for index in downloads.indices where !downloads[index].finished {
            downloads[index].finished = true
            downloads[index].state = "已取消"
        }
    }

    private func startNext() {
        guard activeID == nil, let index = downloads.firstIndex(where: { !$0.finished }) else { return }
        let item = downloads[index]
        activeID = item.id
        downloads[index].state = "下载中…"
        transferTask = Task {
            do {
                try await service.download(alias: alias, path: item.entry.path,
                    directory: item.entry.isDirectory, destination: item.destination)
                try Task.checkCancellation()
                if let i = downloads.firstIndex(where: { $0.id == item.id }) {
                    downloads[i].state = "已完成"
                    downloads[i].succeeded = true
                }
                if item.preview { NSWorkspace.shared.open(item.destination) }
            } catch {
                if let i = downloads.firstIndex(where: { $0.id == item.id }) {
                    downloads[i].state = Task.isCancelled ? "已取消" : error.localizedDescription
                }
            }
            if let i = downloads.firstIndex(where: { $0.id == item.id }) { downloads[i].finished = true }
            activeID = nil
            transferTask = nil
            startNext()
        }
    }
}

struct RemoteFileBrowser: View {
    @StateObject private var model: RemoteFileBrowserModel
    @Environment(\.dismiss) private var dismiss
    init(alias: String, service: RemoteFileService) {
        _model = StateObject(wrappedValue: RemoteFileBrowserModel(alias: alias, service: service))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("远程文件 · " + model.alias, systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.history.isEmpty)
                Button { model.browse((model.path as NSString).deletingLastPathComponent) }
                    label: { Image(systemName: "arrow.up") }
                    .disabled(!model.path.hasPrefix("/") || model.path == "/")
                TextField("远程目录", text: $model.path).onSubmit { model.browse(model.path) }
                Button { model.browse(model.path) } label: { Image(systemName: "arrow.clockwise") }
                Button { model.togglePin() } label: {
                    Image(systemName: model.pins.contains(model.path) ? "pin.fill" : "pin")
                }.disabled(!model.path.hasPrefix("/"))
                Menu("收藏") {
                    ForEach(model.pins, id: \.self) { path in
                        Button(path) { model.browse(path) }
                    }
                }.disabled(model.pins.isEmpty)
            }
            HStack {
                TextField("筛选文件", text: $model.filter)
                Toggle("显示隐藏文件", isOn: $model.showHidden)
                if model.loading { ProgressView().controlSize(.small) }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Table(model.visibleEntries, selection: $model.selection) {
                TableColumn("名称") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .onTapGesture(count: 2) { open(entry) }
                }.width(min: 200, ideal: 330)
                TableColumn("大小") { entry in
                    Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                }.width(90)
                TableColumn("修改时间") { entry in
                    Text(Date(timeIntervalSince1970: entry.modified), style: .date)
                }.width(110)
            }
            HStack {
                Text("\(model.visibleEntries.count) 个项目").foregroundStyle(.secondary)
                Spacer()
                if let entry = model.entries.first(where: { $0.id == model.selection }) {
                    Button(entry.isDirectory ? "打开目录" : "下载并打开") { open(entry) }
                        .disabled(!entry.isDirectory && !entry.isFile)
                    Button("下载所选项目") { model.download(entry) }
                        .disabled(!entry.isDirectory && !entry.isFile)
                }
            }
            if !model.downloads.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.downloads) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.entry.name).lineLimit(1)
                                    Text(item.state).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Spacer()
                                if !item.finished {
                                    Button("取消") { model.cancel(item.id) }
                                } else if item.succeeded {
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
                                    }
                                } else {
                                    Button("重试") { model.retry(item.id) }
                                }
                            }
                        }
                    }
                }.frame(height: 120)
            }
            Text("仅浏览和下载；双击文件下载后用默认应用打开。关闭此窗口会取消未完成的下载。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 800, minHeight: 600)
        .task { model.browse(model.path) }
        .onDisappear { model.stop() }
    }
    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory { model.browse(entry.path) }
        else if entry.isFile { model.download(entry, preview: true) }
    }
}
