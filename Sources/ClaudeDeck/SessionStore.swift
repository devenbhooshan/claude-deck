import AppKit
import SwiftUI
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class SessionStore {
    private(set) var live: [Session] = []
    private(set) var recent: [Session] = []
    var selectedId: String?
    /// Conversation or Activity, for the open session.
    var detailTab: DetailTab = .conversation
    /// A place to open a session at (from search): consumed by the session view.
    var focus: FocusTarget?
    /// Older sessions opened from search (not running, not in Recent).
    private(set) var opened: [Session] = []
    /// The Activity History & search panel over the main window.
    var showHistory = false
    var showSwitcher = false
    var showNewSession = false
    var showUsage = false
    var showPolicies = false
    /// A session we just started (and the terminal it's in): select it as soon as it appears.
    private var starting: (folder: String, at: Date, terminal: String?)?
    /// A session being restarted, and the start times that keep restarted sessions in their slot.
    private(set) var restarting: RestartTicket?
    private var slots: [String: Date] = [:]
    /// Text to drop into the message box (e.g. a skill's command), consumed by the composer.
    var composerInsert: String?
    var lastError: String?
    /// Opens (or re-opens) the main window; set by the window scene.
    var openMainWindow: (() -> Void)?

    /// Session being renamed (drives the rename sheet).
    var renameTarget: Session?
    /// Session to end once you confirm (asked only while Claude is mid-step or at a prompt).
    var endTarget: Session?
    /// Sessions being ended, by session id.
    private(set) var ending: Set<String> = []
    /// Names you've just set, shown until the transcript records them.
    private var pendingNames: [String: String] = [:]
    var hookInstalled = PendingRequests.isInstalled

    func installHook() {
        do {
            try PendingRequests.install()
            hookInstalled = true
        } catch {
            lastError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    /// Renames via Claude Code's own /rename for running sessions, so the name shows everywhere.
    /// Ended sessions get the same custom-title record appended to their transcript.
    func rename(_ s: Session, to raw: String) {
        if s.isLive && s.status == .waiting {
            lastError = "Claude is showing a prompt. Answer it first, then rename."
            return
        }
        guard let name = TranscriptWriter.normalizedName(raw) else { return }
        pendingNames[s.id] = name
        applyNames()
        Task {
            do {
                if s.isLive {
                    try await Ghostty.send(text: "/rename \(name)", to: s)
                } else if let url = s.transcriptURL {
                    try TranscriptWriter.appendCustomTitle(name, sessionId: s.sessionId, to: url)
                }
            } catch {
                pendingNames[s.id] = nil
                applyNames()
                lastError = error.localizedDescription
            }
        }
    }

    private func applyNames() {
        guard !pendingNames.isEmpty else { return }
        let applied = SessionNav.applyPendingNames(live: live, recent: recent, pending: pendingNames)
        live = applied.live
        recent = applied.recent
        pendingNames = applied.pending
    }

    /// Prompts you've just answered, keyed by session id, hidden until Claude's status catches up.
    private(set) var answered: [String: Date] = [:]

    var waitingCount: Int { live.filter { $0.status == .waiting }.count }

    /// Sessions in sidebar order, for keyboard navigation.
    var ordered: [Session] { SessionNav.ordered(live: live, recent: recent) }

    func isAnswered(_ s: Session) -> Bool { SessionNav.isAnswered(at: answered[s.id]) }

    /// Answers a session's prompt by pressing a key in its terminal (enter = allow, escape = deny),
    /// only if it's still the prompt you saw (`expectedSince` defaults to the one on screen).
    func respond(_ s: Session, key: String, expectedSince: Double? = nil) {
        answered[s.id] = Date()
        let since = expectedSince ?? s.statusStamp
        Task {
            do {
                try await Ghostty.press(key: key, on: s, expectedSince: since)
            } catch {
                answered[s.id] = nil
                lastError = error.localizedDescription
            }
        }
    }

    /// Answers a permission prompt from the keyboard, from any app: the selected session if it's
    /// waiting, otherwise the one that has waited longest. Repeat to work through the queue.
    func respondToNext(allow: Bool) {
        guard let (target, remaining) = SessionNav.approvalTarget(live: live, selected: selectedId,
                                                                   isAnswered: isAnswered) else {
            HUD.show("Nothing waiting", symbol: "checkmark.circle", tint: Color.secondary)
            return
        }
        // Never approve blind: Deck must know exactly what's being asked.
        guard PromptGuard.canAnswerHere(target) else {
            HUD.show("Answer this one in the terminal", detail: "\(target.displayTitle): Deck can't see what it's asking",
                     symbol: "exclamationmark.triangle.fill", tint: Theme.waiting)
            return
        }
        respond(target, key: allow ? "enter" : "escape")
        let message = SessionNav.approvalMessage(for: target, allow: allow, remaining: remaining)
        HUD.show(message.title, detail: message.detail,
                 symbol: allow ? "checkmark.circle.fill" : "xmark.circle.fill",
                 tint: allow ? Theme.success : Theme.danger)
    }

    /// Folders you've run Claude in (running first, then recent), that still exist.
    var projectFolders: [String] {
        SessionNav.projectFolders(live: live, recent: recent)
            .filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
    }

    func startSession(in folder: String) {
        starting = (folder, Date(), nil)
        Task {
            do {
                let terminal = try await Ghostty.newSession(in: folder)
                starting?.terminal = terminal
                refresh()
                HUD.show("Starting Claude", detail: Theme.shortPath(folder), symbol: "plus.circle.fill", tint: Theme.accent)
            } catch {
                starting = nil
                lastError = error.localizedDescription
            }
        }
    }

    /// Stops the session's current step.
    func interrupt(_ s: Session) {
        Task {
            do {
                try await Ghostty.interrupt(s)
                HUD.show("Stopped", detail: s.displayTitle, symbol: "stop.circle.fill", tint: Theme.danger)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Quits and resumes the session in its terminal so new skills and MCP servers load. It keeps
    /// its place in the list (and its ⌘ number) throughout.
    func restart(_ s: Session) {
        guard restarting == nil else {
            lastError = "Another session is restarting. Try again in a moment."
            return
        }
        restarting = RestartTicket(session: s, at: Date())
        HUD.show("Restarting", detail: s.displayTitle, symbol: "arrow.clockwise.circle.fill", tint: Theme.accent)
        Task {
            do {
                try await Ghostty.restart(s)
            } catch {
                restarting = nil
                lastError = error.localizedDescription
                refresh()
            }
        }
    }

    /// Ends the session: asks first if Claude is working or waiting on you, since that's cut short.
    func requestEnd(_ s: Session) {
        if s.status == .busy || s.status == .waiting || s.status == .background { endTarget = s } else { end(s) }
    }

    /// Quits Claude in its terminal and closes the terminal. The session stays resumable.
    func end(_ s: Session) {
        guard s.isLive, !ending.contains(s.sessionId) else { return }
        ending.insert(s.sessionId)
        HUD.show("Ending session", detail: s.displayTitle, symbol: "xmark.circle.fill", tint: Theme.accent)
        Task {
            defer { ending.remove(s.sessionId) }
            do {
                try await Ghostty.end(s)
                HUD.show("Session ended", detail: s.displayTitle, symbol: "checkmark.circle.fill", tint: Theme.accent)
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    func openTerminal(_ s: Session) {
        Task {
            do { try await Ghostty.focus(s) } catch { lastError = error.localizedDescription }
        }
    }

    func select(offset: Int) {
        if let id = SessionNav.step(ordered, from: selectedId, by: offset) { selectedId = id }
    }

    func selectNextWaiting() {
        if let id = SessionNav.nextWaiting(live, after: selectedId) { selectedId = id }
    }

    func bringToFront(switcher: Bool = false) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if switcher { showSwitcher = true }
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return live.first { $0.id == id } ?? recent.first { $0.id == id } ?? opened.first { $0.id == id }
    }

    /// Opens a session at a moment (or its latest part when there's no offset), bringing Deck forward.
    /// `stub` stands in for a session that's neither running nor recent.
    func open(_ target: FocusTarget, stub: Session?) {
        if session(target.sessionId) == nil, let stub { opened.append(stub) }
        guard session(target.sessionId) != nil else { return }
        focus = target.offset == nil ? nil : target
        detailTab = .conversation
        showHistory = false
        selectedId = target.sessionId
        bringToFront()
    }

    private var titleCache: [String: TitleInfo] = [:]
    private var previousStatus: [String: SessionStatus] = [:]
    private var lastRecentScan = Date.distantPast
    private var timer: Timer?
    private var watcher: FileWatcher?
    /// One watcher per live session record; Claude Code rewrites these in place on status changes.
    private var recordWatchers: [Int32: FileWatcher] = [:]
    private var refreshPending = false

    func start() {
        AttachmentStore.purge()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DebugLog.write("notifications granted=\(granted) error=\(String(describing: error))")
            if CommandLine.arguments.contains("--test-notification") {
                let c = UNMutableNotificationContent()
                c.title = "Claude Deck test"
                c.body = "If you see this, notifications work."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: c, trigger: nil)) { err in
                    DebugLog.write("test notification add error=\(String(describing: err))")
                }
            }
        }
        refresh()
        // The directory changes when sessions start or exit.
        watcher = FileWatcher(url: ClaudePaths.sessions, events: [.write]) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Coalesces bursts of file events into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        let scanRecent = Date().timeIntervalSince(lastRecentScan) > 20
        if scanRecent { lastRecentScan = Date() }
        let cache = titleCache
        Task.detached(priority: .utility) {
            let (live, cacheUpdates) = SessionLoader.loadLive(cache: cache)
            let recent = scanRecent ? SessionLoader.loadRecent(excluding: Set(live.map(\.sessionId)), cache: cache) : nil
            await MainActor.run { self.apply(live: live, recent: recent, cacheUpdates: cacheUpdates) }
        }
    }

    private func apply(live newLive: [Session], recent newRecent: [Session]?, cacheUpdates: [String: TitleInfo]) {
        for (k, v) in cacheUpdates { titleCache[k] = v }
        for s in newLive where s.status == .waiting && previousStatus[s.id] != nil && previousStatus[s.id] != .waiting {
            notify(s)
        }
        previousStatus = Dictionary(newLive.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        // Keep an optimistic rename until the transcript reports it.
        let named = SessionNav.applyPendingNames(live: newLive, recent: newRecent ?? recent, pending: pendingNames)
        pendingNames = named.pending
        if let t = restarting {
            if let back = SessionNav.restarted(t, in: named.live) {
                slots[back.sessionId] = t.session.startedAt
                if selectedId == t.session.id { selectedId = back.id }
                restarting = nil
            } else if Date().timeIntervalSince(t.at) > 60 {
                restarting = nil
            }
        }
        slots = slots.filter { id, _ in named.live.contains { $0.sessionId == id } }
        let newLive = SessionNav.keepSlots(live: named.live, slots: slots, restarting: restarting)
        if newLive != live { live = newLive }
        // Select a session we just started once Claude Code registers it.
        // Wait for Ghostty to report the new terminal, so the session is bound to it.
        if let start = starting, let terminal = start.terminal {
            // By start time, not activity: another session in the same folder may be busy.
            if let s = newLive.first(where: { $0.cwd == start.folder && ($0.startedAt ?? .distantPast) >= start.at.addingTimeInterval(-2) }) {
                Ghostty.adopt(terminal, for: s.sessionId)
                selectedId = s.id
                starting = nil
            } else if Date().timeIntervalSince(start.at) > 60 {
                starting = nil
            }
        }
        // Forget answers once the session has moved on (or after a timeout).
        answered = SessionNav.pruneAnswered(answered, live: newLive)
        // Captured requests hold full commands; delete them once their prompt is gone.
        let waitingIds = Set(newLive.filter { $0.status == .waiting }.map(\.sessionId))
        DispatchQueue.global(qos: .utility).async { PendingRequests.prune(keeping: waitingIds) }
        syncRecordWatchers(Set(newLive.compactMap(\.pid)))
        if let newRecent {
            let liveIds = Set(newLive.map(\.id))
            recent = newRecent.filter { !liveIds.contains($0.id) }
            applyNames()
        }
        NSApp.dockTile.badgeLabel = waitingCount > 0 ? "\(waitingCount)" : nil
    }

    private func syncRecordWatchers(_ pids: Set<Int32>) {
        for pid in recordWatchers.keys where !pids.contains(pid) { recordWatchers[pid] = nil }
        for pid in pids where recordWatchers[pid] == nil {
            let url = ClaudePaths.sessions.appendingPathComponent("\(pid).json")
            recordWatchers[pid] = FileWatcher(url: url, events: [.write, .extend, .rename, .delete]) { [weak self] in
                MainActor.assumeIsolated {
                    // A rename/delete leaves this watcher on a dead file; drop it so the next sync re-creates it.
                    self?.recordWatchers[pid] = nil
                    self?.scheduleRefresh()
                }
            }
        }
    }

    private func notify(_ s: Session) {
        let text = NotificationText(for: s)
        let content = UNMutableNotificationContent()
        content.title = text.title
        if let subtitle = text.subtitle { content.subtitle = subtitle }
        content.body = text.body
        content.sound = .default
        // Identify the exact prompt, so a stale banner can't answer a newer one.
        content.userInfo = ["sessionId": s.sessionId, "since": s.statusStamp ?? 0]
        if text.isApproval && PromptGuard.canAnswerHere(s) { content.categoryIdentifier = Notifications.approvalCategory }
        DebugLog.write("notify \(s.displayTitle) approval=\(text.isApproval) buttons=\(content.categoryIdentifier == Notifications.approvalCategory) tool=\(s.pendingTool?.name ?? "unknown")")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.sessionId + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil)) { err in
            if let err { DebugLog.write("notify add error=\(err)") }
        }
    }

}

/// A small diagnostic log at ~/Library/Caches/com.devenbhooshan.claudedeck/debug.log (last 200 lines).
enum DebugLog {
    static func write(_ message: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.devenbhooshan.claudedeck/debug.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = (old.split(separator: "\n").suffix(199).map(String.init)) + ["\(Date()) \(message)"]
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Where to open a session: the line of a message or event, and its text to point out.
struct FocusTarget: Equatable {
    let sessionId: String
    let offset: UInt64?
    let text: String?
    var id = UUID()
}
