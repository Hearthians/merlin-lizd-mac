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
        let model = AppModel()
        self.runtime = runtime
        _model = StateObject(wrappedValue: model)
        let terminals = TerminalTabsModel(
                runtime: runtime,
                onRemoteHostUsed: { [weak model] destination, date in
                    model?.recordUse(of: destination, at: date)
                }
        )
        _terminals = StateObject(wrappedValue: terminals)
        appDelegate.configure(runtime: runtime, terminals: terminals)
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
    private weak var terminals: TerminalTabsModel?
    private var terminationTask: Task<Void, Never>?

    func configure(runtime: HubRuntime, terminals: TerminalTabsModel) {
        precondition(self.runtime == nil || self.runtime === runtime)
        self.runtime = runtime
        self.terminals = terminals
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let runtime else { return .terminateNow }
        terminals?.cancelAllAttachments()
        terminationTask = Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
