import AppKit
import MerlinLizdCore
import SwiftUI

@main
struct MerlinLizdApplication: App {
    @NSApplicationDelegateAdaptor(MerlinLizdApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var terminals: TerminalTabsModel
    @StateObject private var codexDrawer: CodexDrawerModel
    private let runtime: MerlinRemoteRuntime

    init() {
        let runtime = MerlinRemoteRuntime()
        self.runtime = runtime
        let model = AppModel(runtime: runtime)
        let terminals = TerminalTabsModel(
            runtime: runtime,
            codexRuntime: runtime.codexRuntime
        )
        _model = StateObject(
            wrappedValue: model
        )
        _terminals = StateObject(
            wrappedValue: terminals
        )
        _codexDrawer = StateObject(
            wrappedValue: CodexDrawerModel(
                runtime: runtime.codexRuntime,
                terminals: terminals
            )
        )
        appDelegate.configure(runtime: runtime)
        model.start()
    }

    var body: some Scene {
        WindowGroup("MerlinHubX") {
            MerlinRootView(
                model: model,
                terminals: terminals,
                codexDrawer: codexDrawer,
                metricsStreamer: runtime.metricsStreamer
            )
                .frame(minWidth: 960, minHeight: 640)
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
    private var runtime: MerlinRemoteRuntime?
    private var terminationTask: Task<Void, Never>?

    func configure(runtime: MerlinRemoteRuntime) {
        precondition(self.runtime == nil || self.runtime === runtime)
        self.runtime = runtime
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let runtime else {
            assertionFailure("App delegate must be configured with its runtime")
            return .terminateNow
        }

        terminationTask = Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
