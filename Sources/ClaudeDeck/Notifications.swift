import AppKit
import UserNotifications

enum Notifications {
    static let approvalCategory = "approval"
    static let allow = "allow"
    static let deny = "deny"

    /// Lets permission notifications be answered straight from the banner.
    static func registerCategories() {
        let category = UNNotificationCategory(
            identifier: approvalCategory,
            actions: [
                UNNotificationAction(identifier: allow, title: "Allow", options: []),
                UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
