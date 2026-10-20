import AppKit
import SwiftUI

struct ForwardedLinksView: View {
    @ObservedObject var model: ForwardedLinksModel
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口转发").font(.largeTitle.bold())
                        Text("保存从远程终端打开的网页，直接恢复连接并重新打开。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAll() }
                    }
                }

                if let notice {
                    MessageBanner(text: notice, kind: .warning)
                }
                if let restorationNotice = model.restorationNotice {
                    MessageBanner(text: restorationNotice, kind: .warning)
                }

                if model.records.isEmpty {
                    SurfaceCard {
                        ContentUnavailableView(
                            "还没有保存的链接",
                            systemImage: "network",
                            description: Text("在远程终端打开 localhost 或 127.0.0.1 网页后，链接会自动保存在这里。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else {
                    ForEach(model.records.sorted { $0.lastUsed > $1.lastUsed }) { record in
                        savedLinkCard(record)
                    }
                }

                Text("转发在 TmuxHub 运行期间保持，并会在重新打开应用或 Mac 唤醒后恢复。关闭终端标签不会停止转发。转发就绪只表示 SSH 通道已建立，远端网页服务仍需保持运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("链接完整参数保存在本机以便重新打开；页面显示时隐藏查询参数和片段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func savedLinkCard(_ record: ForwardedLinkRecord) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(record.destination, systemImage: "server.rack").font(.headline)
                    Spacer()
                    statusLabel(model.status(for: record.id))
                }
                address("远端地址", value: record.displayURL)
                if let localURL = model.localURL(for: record.id) {
                    address("本地地址", value: ForwardedLinksModel.displayURL(localURL.absoluteString))
                } else if let port = record.localPort {
                    address("保留本地端口", value: String(port))
                }

                if case let .failed(message) = model.status(for: record.id) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        connectionButtons(record)
                        recordButtons(record)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { connectionButtons(record) }
                        HStack(spacing: 8) { recordButtons(record) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func connectionButtons(_ record: ForwardedLinkRecord) -> some View {
        Button("打开", systemImage: "arrow.up.forward.app") {
            run(record.id, openBrowser: true)
        }
        Button(record.enabled ? "重新连接" : "恢复转发", systemImage: "arrow.clockwise") {
            run(record.id, openBrowser: false)
        }
        if record.enabled {
            Button("停止转发", systemImage: "stop.circle") {
                Task { await model.stop(id: record.id) }
            }
            .help("同一主机和远端端口的所有保存链接都会停止转发，远端服务继续运行。")
        }
    }

    @ViewBuilder
    private func recordButtons(_ record: ForwardedLinkRecord) -> some View {
        Button("复制本地链接", systemImage: "doc.on.doc") {
            guard let url = model.localURL(for: record.id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(model.localURL(for: record.id) == nil)
        Button("移除记录", systemImage: "trash", role: .destructive) {
            Task { await model.remove(id: record.id) }
        }
        .help("移除这条链接；同一端口的其他已保存链接仍可继续使用。")
    }

    private func address(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .help(value)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: ForwardedLinkStatus) -> some View {
        switch status {
        case .saved:
            Label("待恢复", systemImage: "clock").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在恢复").foregroundStyle(.secondary)
            }
        case .ready:
            Label("转发已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Label("已停止", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed:
            Label("恢复失败", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func run(_ id: UUID, openBrowser: Bool) {
        notice = nil
        Task {
            do {
                let url = try await model.reopen(id: id)
                if openBrowser, !NSWorkspace.shared.open(url) {
                    notice = "转发已就绪，但系统浏览器无法打开链接。"
                }
            } catch is CancellationError {
            } catch {
                notice = model.displayError(error, id: id)
            }
        }
    }
}
