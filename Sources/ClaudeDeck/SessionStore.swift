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
    var showSwitcher = false
    var lastError: String?
    /// Opens (or re-opens) the main window; set by the window scene.
    var openMainWindow: (() -> Void)?

    /// Session being renamed (drives the rename sheet).
    var renameTarget: Session?
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

    /// Answers a session's prompt by pressing a key in its terminal (enter = allow, escape = deny).
    func respond(_ s: Session, key: String) {
        answered[s.id] = Date()
        Task {
            do {
                try await Ghostty.press(key: key, on: s)
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
        respond(target, key: allow ? "enter" : "escape")
        let message = SessionNav.approvalMessage(for: target, allow: allow, remaining: remaining)
        HUD.show(message.title, detail: message.detail,
                 symbol: allow ? "checkmark.circle.fill" : "xmark.circle.fill",
                 tint: allow ? Theme.success : Theme.danger)
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
        return live.first { $0.id == id } ?? recent.first { $0.id == id }
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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
        let newLive = named.live
        if newLive != live { live = newLive }
        // Forget answers once the session has moved on (or after a timeout).
        answered = SessionNav.pruneAnswered(answered, live: newLive)
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
        content.userInfo = ["sessionId": s.sessionId]
        if text.isApproval { content.categoryIdentifier = Notifications.approvalCategory }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.sessionId + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

}
