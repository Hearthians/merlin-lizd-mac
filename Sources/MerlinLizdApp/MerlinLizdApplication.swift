import AppKit
import MerlinLizdCore
import SwiftUI

@main
struct MerlinLizdApplication: App {
    @NSApplicationDelegateAdaptor(MerlinLizdApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var terminals: TerminalTabsModel
    private let runtime: MerlinRemoteRuntime

    init() {
        let runtime = MerlinRemoteRuntime()
        self.runtime = runtime
        let model = AppModel(runtime: runtime)
        let terminals = TerminalTabsModel(runtime: runtime)
        _model = StateObject(
            wrappedValue: model
        )
        _terminals = StateObject(
            wrappedValue: terminals
        )
        model.start()
    }

    var body: some Scene {
        WindowGroup("Merlin Lizd") {
            MerlinRootView(
                model: model,
                terminals: terminals,
                metricsStreamer: runtime.metricsStreamer
            )
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.configure(runtime: runtime)
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
    private var runtime: MerlinRemoteRuntime?

    func configure(runtime: MerlinRemoteRuntime) {
        self.runtime = runtime
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else { return .terminateLater }
        isFinishingTermination = true

        Task {
            await runtime?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
