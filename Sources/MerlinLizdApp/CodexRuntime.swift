import Foundation
import MerlinLizdCodexAdapter
import MerlinLizdCore

@MainActor
final class CodexRuntime {
    let tmuxController: TmuxSessionController
    let approvalBroker: TerminalApprovalBroker
    let registry: TerminalEndpointRegistry
    let router: TerminalToolRouter
    let journalReader: any TerminalOperationJournalReading
    let supervisor: CodexAppServerSupervisor
    let coordinator: CodexSessionCoordinator

    private let notificationController: CodexNotificationController
    private var isShuttingDown = false

    init(
        tmuxController: TmuxSessionController,
        fileManager: FileManager = .default
    ) throws {
        let applicationSupportDirectory = try Self.applicationSupportDirectory(
            fileManager: fileManager
        )
        let runtimeDirectory = applicationSupportDirectory
            .appendingPathComponent("MerlinLizd", isDirectory: true)
            .appendingPathComponent("CodexRuntime", isDirectory: true)
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeDirectory.path
        )

        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let approvalBroker = TerminalApprovalBroker()
        let registry = TerminalEndpointRegistry()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: approvalBroker,
            journal: journal
        )
        let mappingStore = CodexAppServerThreadMappingStore()
        let supervisor = CodexAppServerSupervisor(
            runtimeDirectory: runtimeDirectory,
            toolExecutor: CodexTerminalToolExecutor(router: router),
            mappingStore: mappingStore
        )

        self.tmuxController = tmuxController
        self.approvalBroker = approvalBroker
        self.registry = registry
        self.router = router
        journalReader = journal
        self.supervisor = supervisor
        coordinator = CodexSessionCoordinator(
            agent: supervisor,
            store: store,
            registry: registry,
            router: router,
            journal: journal
        )
        notificationController = CodexNotificationController()
    }

    func startNotifications(
        foregroundConversation: @escaping @MainActor @Sendable ()
            -> TerminalConversationKey?,
        openConversation: @escaping @MainActor @Sendable (
            TerminalConversationKey
        ) -> Void
    ) {
        guard !isShuttingDown else { return }
        notificationController.start(
            coordinator: coordinator,
            foregroundConversation: foregroundConversation,
            openConversation: openConversation
        )
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        notificationController.stop()
        await coordinator.shutdown()
    }

    private static func applicationSupportDirectory(
        fileManager: FileManager
    ) throws -> URL {
        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
