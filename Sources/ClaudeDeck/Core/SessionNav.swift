import Foundation

/// Sidebar ordering, keyboard navigation and approval targeting: the decisions behind
/// ⌘1–9, ⌥⌘↑/↓, ⌘J and ⌥⌘↩ / ⌥⌘⌫.
enum SessionNav {
    /// How long an answered prompt stays hidden while Claude's status catches up.
    static let answeredTimeout: TimeInterval = 5

    /// Sidebar order: running sessions in their fixed (start-time) order, then recent ones.
    /// A running session's position, and so its number and ⌘-shortcut, never changes while it runs.
    static func ordered(live: [Session], recent: [Session]) -> [Session] {
        live + recent
    }

    /// Unique project folders, running sessions first, then recent, in order.
    static func projectFolders(live: [Session], recent: [Session]) -> [String] {
        var seen = Set<String>()
        return (live + recent).map(\.cwd).filter { seen.insert($0).inserted }
    }

    /// The id `offset` places from the selection, wrapping around. With nothing selected,
    /// moving forward starts at the first session and moving back at the last.
    static func step(_ list: [Session], from selected: String?, by offset: Int) -> String? {
        guard !list.isEmpty else { return nil }
        let i = list.firstIndex { $0.id == selected } ?? (offset > 0 ? -1 : list.count)
        return list[((i + offset) % list.count + list.count) % list.count].id
    }

    /// The next session that needs you after the selection, wrapping around.
    static func nextWaiting(_ live: [Session], after selected: String?) -> String? {
        let waiting = live.filter { $0.status == .waiting }
        guard !waiting.isEmpty else { return nil }
        let i = waiting.firstIndex { $0.id == selected } ?? -1
        return waiting[(i + 1) % waiting.count].id
    }

    /// Permission prompts can be answered with Allow / Deny; other waits (questions) need the terminal.
    static func isPermission(_ s: Session) -> Bool {
        s.waitingFor?.localizedCaseInsensitiveContains("permission") ?? false
    }

    static func isAnswered(at: Date?, now: Date = Date()) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < answeredTimeout
    }

    /// Answers to keep: only for sessions still waiting, and not yet timed out.
    static func pruneAnswered(_ answered: [String: Date], live: [Session], now: Date = Date()) -> [String: Date] {
        let waiting = Set(live.filter { $0.status == .waiting }.map(\.id))
        return answered.filter { waiting.contains($0.key) && isAnswered(at: $0.value, now: now) }
    }

    /// Which prompt ⌥⌘↩ / ⌥⌘⌫ answers: the selected session if it's waiting on a permission
    /// prompt, otherwise the one that has waited longest. Also returns how many others are waiting.
    static func approvalTarget(live: [Session], selected: String?,
                               isAnswered: (Session) -> Bool) -> (session: Session, remaining: Int)? {
        let open = live.filter { $0.status == .waiting && !isAnswered($0) && isPermission($0) }
        let target = open.first { $0.id == selected }
            ?? open.min { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }
        return target.map { ($0, open.count - 1) }
    }

    /// The HUD text after answering from the keyboard.
    static func approvalMessage(for s: Session, allow: Bool, remaining: Int) -> (title: String, detail: String) {
        let what = s.pendingTool.map { "\(ToolStyle.displayName($0.name)): \($0.summary)" } ?? s.projectName
        return ((allow ? "Allowed · " : "Denied · ") + s.displayTitle,
                remaining > 0 ? "\(what) — \(remaining) more waiting" : what)
    }

    /// Applies names you've just set until the transcript reports them. Returns the sessions to
    /// show and the names still waiting to be confirmed.
    static func applyPendingNames(live: [Session], recent: [Session], pending: [String: String])
        -> (live: [Session], recent: [Session], pending: [String: String]) {
        var live = live, recent = recent, pending = pending
        for (id, name) in pending {
            let confirmed = (live + recent).contains { $0.id == id && $0.title == name }
            if confirmed {
                pending[id] = nil
                continue
            }
            if let i = live.firstIndex(where: { $0.id == id }) { live[i].title = name }
            if let i = recent.firstIndex(where: { $0.id == id }) { recent[i].title = name }
        }
        return (live, recent, pending)
    }

    /// The session that came back from a restart: the same id under a new process, or (if Claude
    /// gave it a new id) a new session in the same folder that started after the restart.
    static func restarted(_ t: RestartTicket, in live: [Session]) -> Session? {
        live.first { $0.sessionId == t.session.sessionId && $0.pid != t.session.pid }
            ?? live.first {
                $0.sessionId != t.session.sessionId && $0.cwd == t.session.cwd
                    && ($0.startedAt ?? .distantPast) >= t.at.addingTimeInterval(-2)
            }
    }

    /// Keeps restarted sessions in their numbered place: remembered start times win, and a session
    /// mid-restart holds its slot until it's back.
    static func keepSlots(live: [Session], slots: [String: Date], restarting: RestartTicket?) -> [Session] {
        var out = live.map { s in
            var s = s
            if let d = slots[s.sessionId] { s.startedAt = d }
            return s
        }
        if let t = restarting, !out.contains(where: { $0.sessionId == t.session.sessionId }) { out.append(t.session) }
        return out.sorted(by: SessionLoader.startOrder)
    }
}

/// A session being restarted (quit, then resumed in the same terminal), as it was before.
struct RestartTicket: Equatable {
    let session: Session
    let at: Date
}
