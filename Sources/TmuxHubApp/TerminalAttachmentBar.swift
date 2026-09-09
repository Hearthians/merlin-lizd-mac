import SwiftUI
import TmuxHubCore

struct TerminalAttachmentBar: View {
    @ObservedObject var model: TerminalAttachmentModel
    @State private var showDirectory = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.items.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.items) { item in row(item) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: min(CGFloat(model.items.count) * 48 + 16, 160))
            }
            if let message = model.message {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }
            HStack(spacing: 12) {
                Button("添加文件", systemImage: "paperclip") { model.chooseFiles() }
                Button("粘贴截图", systemImage: "photo.on.rectangle") { model.pasteImage() }
                Spacer()
                Text("拖入文件 / ⌘V 截图 · 不自动发送")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { showDirectory = true } label: { Image(systemName: "folder.badge.gearshape") }
                    .help("附件目录")
                    .popover(isPresented: $showDirectory) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("附件目录").font(.headline)
                            Text(model.target.sshDestination.map { "远端：\($0)" } ?? "本机")
                                .font(.caption.monospaced())
                            TextField("留空使用当前会话工作目录", text: $model.directoryOverride)
                                .textFieldStyle(.roundedBorder)
                            Text("输入已有目录的绝对路径。文件将放到其 .tmuxhub/attachments/ 下；本地普通文件直接引用原路径。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("仅插入路径；是否识别为图片附件取决于当前 agent CLI。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("保存") { model.saveDirectory(); if model.message == nil { showDirectory = false } }
                        }.padding(16).frame(width: 380)
                    }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func row(_ item: TerminalAttachment) -> some View {
        HStack(spacing: 8) {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
            } else {
                Image(systemName: "doc.fill").foregroundStyle(.secondary).frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.lastPathComponent).font(.caption).lineLimit(1)
                Text(item.phase.label).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
            if item.phase.active {
                ProgressView().controlSize(.small)
                Button("取消") { model.cancel(item.id) }
            } else {
                if item.path != nil {
                    Button(item.phase == .inserted ? "再次插入" : "插入") { model.insert(item.id) }
                    Button { model.copyPath(item.id) } label: { Image(systemName: "doc.on.doc") }
                        .help("复制可访问路径")
                } else {
                    Button("重试") { model.retry(item.id) }
                }
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .help("移除记录（不会删除附件文件）")
            }
        }
        .buttonStyle(.borderless)
        .help(item.path ?? item.source.path)
    }
}
