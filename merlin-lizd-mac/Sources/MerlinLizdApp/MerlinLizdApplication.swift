import AppKit
import MerlinLizdCore
import SwiftUI

@main
struct MerlinLizdApplication: App {
    @NSApplicationDelegateAdaptor(MerlinLizdApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var terminals: TerminalTabsModel
    private let sshMasterPool: SSHMasterPool
    private let metricsStreamer: WorkerMetricsStreamer

    init() {
        let pool = SSHMasterPool(maxConcurrentPreparations: 4)
        let discovery = TmuxSessionDiscovery(sshMasterPool: pool)
        let controller = TmuxSessionController(sshMasterPool: pool)
        sshMasterPool = pool
        metricsStreamer = WorkerMetricsStreamer(sshMasterPool: pool)
        _model = StateObject(
            wrappedValue: AppModel(sshMasterPool: pool)
        )
        _terminals = StateObject(
            wrappedValue: TerminalTabsModel(
                sshMasterPool: pool,
                tmuxSessionDiscovery: discovery,
                tmuxSessionController: controller
            )
        )
    }

    var body: some Scene {
        WindowGroup("Merlin Lizd") {
            MerlinRootView(
                model: model,
                terminals: terminals,
                metricsStreamer: metricsStreamer
            )
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.configure(sshMasterPool: sshMasterPool)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建本机终端") {
                    terminals.openLocal()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Button("上一个标签页") {
                    terminals.selectPreviousTab()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(terminals.tabs.isEmpty)

                Button("下一个标签页") {
                    terminals.selectNextTab()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(terminals.tabs.isEmpty)
            }
        }
    }
}

@MainActor
private final class MerlinLizdApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isFinishingTermination = false
    private var sshMasterPool: SSHMasterPool?

    func configure(sshMasterPool: SSHMasterPool) {
        self.sshMasterPool = sshMasterPool
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else { return .terminateLater }
        isFinishingTermination = true

        Task {
            await WorkerMetricsStreamer.shutdownAll()
            await sshMasterPool?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
