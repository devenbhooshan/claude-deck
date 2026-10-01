import Foundation

/// What a "needs you" notification says.
struct NotificationText: Equatable {
    let title: String
    let subtitle: String?
    let body: String
    /// Permission prompts get Allow / Deny buttons on the banner.
    let isApproval: Bool

    init(for s: Session) {
        title = s.displayTitle
        if let tool = s.pendingTool {
            subtitle = "\(s.projectName) · \(ToolStyle.displayName(tool.name))"
            body = String(tool.summary.prefix(180))
        } else {
            subtitle = nil
            body = "\(s.projectName) is waiting for \(s.waitingFor ?? "your input")"
        }
        isApproval = SessionNav.isPermission(s)
    }
}
