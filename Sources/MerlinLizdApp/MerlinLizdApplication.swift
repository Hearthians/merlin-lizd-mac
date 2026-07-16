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
        appDelegate.configure(runtime: runtime, terminals: terminals)
        model.start()
    }

    var body: some Scene {
        WindowGroup("MerlinHub") {
            MerlinRootView(
                model: model,
                terminals: terminals,
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
    private var terminals: TerminalTabsModel?
    private var terminationTask: Task<Void, Never>?
    private var closeTabKeyMonitor: Any?

    func configure(runtime: MerlinRemoteRuntime, terminals: TerminalTabsModel) {
        precondition(self.runtime == nil || self.runtime === runtime)
        self.runtime = runtime
        self.terminals = terminals
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCloseTabMenuCommand()
        DispatchQueue.main.async { [weak self] in
            self?.installCloseTabMenuCommand()
        }
        closeTabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.charactersIgnoringModifiers == "w" else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == [.command] else { return event }

            self?.terminals?.closeSelectedTab()
            return nil
        }
    }

    private func installCloseTabMenuCommand() {
        guard let closeItem = NSApp.mainMenu?
            .items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .first(where: { $0.action == #selector(NSWindow.performClose(_:)) })
        else {
            return
        }
        closeItem.title = "关闭当前标签页"
        closeItem.target = self
        closeItem.action = #selector(closeSelectedTab(_:))
    }

    @objc private func closeSelectedTab(_ sender: Any?) {
        terminals?.closeSelectedTab()
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
