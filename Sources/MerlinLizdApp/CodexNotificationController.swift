import Foundation
import MerlinLizdCore
@preconcurrency import UserNotifications

@MainActor
private protocol CodexNotificationDelivering: AnyObject {
    var responseHandler: (@MainActor @Sendable (String) -> Void)? { get set }
    func requestAuthorization()
    func deliver(identifier: String, title: String, body: String)
    func stop()
}

@MainActor
final class CodexNotificationController {
    private static let maximumTrackedRequests = 128

    private let delivery: any CodexNotificationDelivering
    private var activityTask: Task<Void, Never>?
    private var foregroundConversation: (
        @MainActor @Sendable () -> TerminalConversationKey?
    )?
    private var openConversation: (
        @MainActor @Sendable (TerminalConversationKey) -> Void
    )?
    private var tracker = CodexApprovalNotificationTracker(
        limit: maximumTrackedRequests
    )

    init() {
        delivery = UserNotificationDelivery()
    }

    private init(delivery: any CodexNotificationDelivering) {
        self.delivery = delivery
    }

    func start(
        coordinator: CodexSessionCoordinator,
        foregroundConversation: @escaping @MainActor @Sendable ()
            -> TerminalConversationKey?,
        openConversation: @escaping @MainActor @Sendable (
            TerminalConversationKey
        ) -> Void
    ) {
        stop()
        self.foregroundConversation = foregroundConversation
        self.openConversation = openConversation
        delivery.responseHandler = { [weak self] identifier in
            self?.openNotification(identifier)
        }
        delivery.requestAuthorization()
        activityTask = Task { [weak self] in
            let events = await coordinator.activityEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.consume(event)
            }
        }
    }

    func stop() {
        activityTask?.cancel()
        activityTask = nil
        delivery.responseHandler = nil
        delivery.stop()
        foregroundConversation = nil
        openConversation = nil
        tracker.removeAll()
    }

    private func consume(_ event: CodexSessionActivityEvent) {
        let candidates = tracker.consume(
            event,
            foreground: foregroundConversation?()
        )
        for candidate in candidates {
            delivery.deliver(
                identifier: candidate.identifier,
                title: "Codex needs approval",
                body: "Open Merlin Lizd to review this request."
            )
        }
    }

    private func openNotification(_ identifier: String) {
        guard let key = tracker.conversation(for: identifier) else { return }
        openConversation?(key)
    }
}

@MainActor
private final class UserNotificationDelivery: NSObject,
    CodexNotificationDelivering, UNUserNotificationCenterDelegate
{
    var responseHandler: (@MainActor @Sendable (String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }

    func stop() {
        responseHandler = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        completionHandler()
        Task { @MainActor [weak self] in
            self?.responseHandler?(identifier)
        }
    }
}
