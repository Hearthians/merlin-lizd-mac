import SwiftUI

@main
struct MerlinLizdApplication: App {
    @StateObject private var model = AppModel()
    @StateObject private var terminals = TerminalTabsModel()

    var body: some Scene {
        WindowGroup("Merlin Lizd") {
            MerlinRootView(model: model, terminals: terminals)
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
            }
        }
    }
}
