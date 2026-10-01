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
                // Approving runs something on your Mac, so it needs the Mac unlocked.
                UNNotificationAction(identifier: allow, title: "Allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: [],
            // Commands can contain secrets: hide them when previews are hidden (e.g. on the lock screen).
            hiddenPreviewsBodyPlaceholder: "Claude needs your approval",
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
