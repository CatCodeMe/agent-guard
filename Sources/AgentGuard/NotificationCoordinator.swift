import AppKit
import Foundation
@preconcurrency import UserNotifications

enum NotificationAction: String, Sendable {
    case allowOnce = "AG_ALLOW_ONCE"
    case block = "AG_BLOCK"
    case open = "AG_OPEN"
}

/// Owns local notification categories and forwards user actions to the main store.
/// Notification text intentionally contains a rule name, not the sensitive path.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    var onAction: (@MainActor @Sendable (UUID, NotificationAction) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        let actions = [
            UNNotificationAction(
                identifier: NotificationAction.allowOnce.rawValue,
                title: "允许一次",
                options: []
            ),
            UNNotificationAction(
                identifier: NotificationAction.block.rawValue,
                title: "阻止",
                options: [.destructive]
            ),
            UNNotificationAction(
                identifier: NotificationAction.open.rawValue,
                title: "打开 Agent Guard",
                options: [.foreground]
            ),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "AG_PREVIEW_EVENT",
                actions: actions,
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func sendTestEvent(id: UUID, ruleName: String, configuredAction: String) {
        let center = self.center
        let onError = self.onError
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Task { @MainActor in onError?(error.localizedDescription) }
                return
            }
            guard granted else {
                Task { @MainActor in onError?("通知权限未开启，请在系统设置中允许 Agent Guard 发送通知。") }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Agent Guard 测试事件"
            content.body = "规则：\(ruleName) · 配置动作：\(configuredAction)\n这是模拟事件，不会访问或阻止文件。"
            content.sound = .default
            content.categoryIdentifier = "AG_PREVIEW_EVENT"
            let request = UNNotificationRequest(
                identifier: id.uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Task { @MainActor in onError?(error.localizedDescription) }
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let id = UUID(uuidString: response.notification.request.identifier),
              let action = NotificationAction(rawValue: response.actionIdentifier)
        else { return }
        Task { @MainActor [weak self] in
            self?.onAction?(id, action)
            if action == .open {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
