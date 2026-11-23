import Foundation
import UserNotifications

/// macOS notifications for new activity, with Done / Mark read buttons on the banner.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    /// Called with a thread id when a banner is clicked or one of its buttons is used.
    var onOpen: ((String) -> Void)?
    var onDone: ((String) -> Void)?
    var onRead: ((String) -> Void)?

    func setUp() {
        center.delegate = self
        let done = UNNotificationAction(identifier: "done", title: "Done")
        let read = UNNotificationAction(identifier: "read", title: "Mark as read")
        center.setNotificationCategories([UNNotificationCategory(identifier: "thread", actions: [done, read], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ list: [GHNotification]) {
        // A burst (first sync after a long sleep) becomes one summary instead of a wall of banners.
        if list.count > 4 {
            let content = UNMutableNotificationContent()
            content.title = "\(list.count) new GitHub notifications"
            content.body = Set(list.map(\.repository.fullName)).sorted().prefix(4).joined(separator: ", ")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "summary-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
            return
        }
        for n in list {
            let content = UNMutableNotificationContent()
            content.title = n.subject.title
            let number = n.number.map { " #\($0)" } ?? ""
            content.subtitle = "\(n.repository.fullName)\(number)"
            content.body = "\(Reason.label(n.reason)) · \(n.kind.label)"
            content.sound = .default
            content.categoryIdentifier = "thread"
            content.threadIdentifier = n.repository.fullName
            content.userInfo = ["thread": n.id]
            center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
        }
    }

    func remove(threadID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [threadID])
    }

    func removeAll() { center.removeAllDeliveredNotifications() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let thread = response.notification.request.content.userInfo["thread"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let thread else {
                self.onOpen?("")
                return
            }
            switch action {
            case "done": self.onDone?(thread)
            case "read": self.onRead?(thread)
            default: self.onOpen?(thread)
            }
        }
    }
}
