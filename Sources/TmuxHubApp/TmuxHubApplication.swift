import AppKit
import TmuxHubCore
import SwiftUI

@main
struct TmuxHubApplication: App {
    @NSApplicationDelegateAdaptor(TmuxHubApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var terminals: TerminalTabsModel
    @StateObject private var hpc2: HPC2PlatformModel
    @StateObject private var hpc3: HPC2PlatformModel
    @StateObject private var hpc4: HPC2PlatformModel
    @StateObject private var mesh: NetworkMeshModel
    private let runtime: HubRuntime

    init() {
        let runtime = HubRuntime()
        let model = AppModel()
        self.runtime = runtime
        _model = StateObject(wrappedValue: model)
        _mesh = StateObject(wrappedValue: NetworkMeshModel())
        let terminals = TerminalTabsModel(
                runtime: runtime,
                onRemoteHostUsed: { [weak model] destination, date in
                    model?.recordUse(of: destination, at: date)
                }
        )
        _terminals = StateObject(wrappedValue: terminals)
        runtime.codexNotifications.onOpen = { [weak terminals, weak model] entry in
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            model?.selection = .notifications
            terminals?.openCodexNotification(entry)
        }
        _hpc2 = StateObject(wrappedValue: HPC2PlatformModel(
            service: runtime.slurmService
        ))
        _hpc3 = StateObject(wrappedValue: HPC2PlatformModel(service: runtime.slurmService, cluster: .hpc3))
        _hpc4 = StateObject(wrappedValue: HPC2PlatformModel(service: runtime.slurmService, cluster: .hpc4))
        appDelegate.configure(runtime: runtime, terminals: terminals)
    }

    var body: some Scene {
        WindowGroup("TmuxHub") {
            TmuxHubRootView(
                model: model, terminals: terminals,
                hpc2: hpc2, hpc3: hpc3, hpc4: hpc4,
                mesh: mesh, forwardedLinks: runtime.forwardedLinks,
                notifications: runtime.codexNotifications
            )
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1160, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AddSSHHostCommands()
            WindowChromeCommands()
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
