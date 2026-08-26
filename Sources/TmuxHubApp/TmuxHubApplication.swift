import AppKit
import TmuxHubCore
import SwiftUI

@main
struct TmuxHubApplication: App {
    @NSApplicationDelegateAdaptor(TmuxHubApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var terminals: TerminalTabsModel
    private let runtime: HubRuntime

    init() {
        let runtime = HubRuntime()
        self.runtime = runtime
        _model = StateObject(wrappedValue: AppModel())
        _terminals = StateObject(
            wrappedValue: TerminalTabsModel(runtime: runtime)
        )
        appDelegate.configure(runtime: runtime)
    }

    var body: some Scene {
        WindowGroup("TmuxHub") {
            TmuxHubRootView(model: model, terminals: terminals)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1160, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建本机终端") {
                    terminals.openLocalShell()
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
private final class TmuxHubApplicationDelegate: NSObject,
    NSApplicationDelegate
{
    private var runtime: HubRuntime?
    private var terminationTask: Task<Void, Never>?

    func configure(runtime: HubRuntime) {
        precondition(self.runtime == nil || self.runtime === runtime)
        self.runtime = runtime
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let runtime else { return .terminateNow }
        terminationTask = Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
