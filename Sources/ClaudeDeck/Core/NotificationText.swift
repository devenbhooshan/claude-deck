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
            body = Self.preview(tool.summary)
        } else {
            subtitle = nil
            body = "\(s.projectName) is waiting for \(s.waitingFor ?? "your input")"
        }
        isApproval = SessionNav.isPermission(s)
    }

    /// A one-paragraph preview that can't hide anything: newlines are shown as ⏎ and a cut is marked.
    static func preview(_ text: String, limit: Int = 180) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > limit ? String(flat.prefix(limit)) + "… (\(text.count) chars)" : flat
    }
}
