import AppKit
import SwiftUI
import Foundation
import Observation
import UserNotifications

struct TitleInfo {
    let mtime: Date
    let title: String?
    let isCustom: Bool
}

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
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !name.isEmpty else { return }
        pendingNames[s.id] = name
        applyNames()
        Task {
            do {
                if s.isLive {
                    try await Ghostty.send(text: "/rename \(name)", to: s)
                } else if let url = s.transcriptURL {
                    let record: [String: Any] = ["type": "custom-title", "customTitle": name, "sessionId": s.sessionId]
                    var line = try JSONSerialization.data(withJSONObject: record)
                    line.append(UInt8(ascii: "\n"))
                    let h = try FileHandle(forWritingTo: url)
                    try h.seekToEnd()
                    try h.write(contentsOf: line)
                    try h.close()
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
        for (id, name) in pendingNames {
            if let i = live.firstIndex(where: { $0.id == id }) { live[i].title = name }
            if let i = recent.firstIndex(where: { $0.id == id }) { recent[i].title = name }
        }
    }

    /// Prompts you've just answered, keyed by session id, hidden until Claude's status catches up.
    private(set) var answered: [String: Date] = [:]

    var waitingCount: Int { live.filter { $0.status == .waiting }.count }

    /// Sessions in sidebar order, for keyboard navigation.
    var ordered: [Session] {
        live.filter { $0.status == .waiting } + live.filter { $0.status != .waiting } + recent
    }

    func isAnswered(_ s: Session) -> Bool {
        guard let at = answered[s.id] else { return false }
        return Date().timeIntervalSince(at) < 5
    }

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
        let open = live.filter {
            $0.status == .waiting && !isAnswered($0)
                && ($0.waitingFor?.localizedCaseInsensitiveContains("permission") ?? false)
        }
        let target = open.first { $0.id == selectedId }
            ?? open.min { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }
        guard let target else {
            HUD.show("Nothing waiting", symbol: "checkmark.circle", tint: Color.secondary)
            return
        }
        respond(target, key: allow ? "enter" : "escape")
        let remaining = open.count - 1
        let what = target.pendingTool.map { "\(ToolStyle.displayName($0.name)): \($0.summary)" } ?? target.projectName
        HUD.show(allow ? "Allowed · \(target.displayTitle)" : "Denied · \(target.displayTitle)",
                 detail: remaining > 0 ? "\(what) — \(remaining) more waiting" : what,
                 symbol: allow ? "checkmark.circle.fill" : "xmark.circle.fill",
                 tint: allow ? Theme.success : Theme.danger)
    }

    func openTerminal(_ s: Session) {
        Task {
            do { try await Ghostty.focus(s) } catch { lastError = error.localizedDescription }
        }
    }

    func select(offset: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedId } ?? (offset > 0 ? -1 : list.count)
        selectedId = list[(i + offset + list.count) % list.count].id
    }

    func selectNextWaiting() {
        let waiting = live.filter { $0.status == .waiting }
        guard !waiting.isEmpty else { return }
        let i = waiting.firstIndex { $0.id == selectedId } ?? -1
        selectedId = waiting[(i + 1) % waiting.count].id
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
            let (live, cacheUpdates) = Self.loadLive(cache: cache)
            let recent = scanRecent ? Self.loadRecent(excluding: Set(live.map(\.sessionId)), cache: cache) : nil
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
        var newLive = newLive
        for (id, name) in pendingNames {
            if newLive.contains(where: { $0.id == id && $0.title == name }) || recent.contains(where: { $0.id == id && $0.title == name && newRecent != nil }) {
                pendingNames[id] = nil
            } else if let i = newLive.firstIndex(where: { $0.id == id }) {
                newLive[i].title = name
            }
        }
        if newLive != live { live = newLive }
        // Forget answers once the session has moved on (or after a timeout).
        let waitingIds = Set(newLive.filter { $0.status == .waiting }.map(\.id))
        answered = answered.filter { waitingIds.contains($0.key) && Date().timeIntervalSince($0.value) < 5 }
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
        let content = UNMutableNotificationContent()
        content.title = s.displayTitle
        if let tool = s.pendingTool {
            content.subtitle = "\(s.projectName) · \(ToolStyle.displayName(tool.name))"
            content.body = String(tool.summary.prefix(180))
        } else {
            content.body = "\(s.projectName) is waiting for \(s.waitingFor ?? "your input")"
        }
        content.sound = .default
        content.userInfo = ["sessionId": s.sessionId]
        if s.waitingFor?.localizedCaseInsensitiveContains("permission") ?? false {
            content.categoryIdentifier = Notifications.approvalCategory
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.sessionId + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    // MARK: - Loading (off the main actor)

    nonisolated private static func loadLive(cache: [String: TitleInfo]) -> ([Session], [String: TitleInfo]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: ClaudePaths.sessions.path) else { return ([], [:]) }
        let requests = PendingRequests.load()
        var updates: [String: TitleInfo] = [:]
        var sessions: [String: Session] = [:]
        for file in files where file.hasSuffix(".json") {
            let url = ClaudePaths.sessions.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let rec = try? JSONDecoder().decode(SessionRecord.self, from: data),
                  isAlive(rec.pid) else { continue }
            let transcript = ClaudePaths.transcript(for: rec.sessionId, cwd: rec.cwd)
            let (title, update) = title(for: transcript, cache: cache)
            if let transcript, let update { updates[transcript.path] = update }
            let status: SessionStatus = switch rec.status {
            case "waiting": .waiting
            case "busy": .busy
            default: .idle
            }
            var s = Session(
                sessionId: rec.sessionId, pid: rec.pid, cwd: rec.cwd, name: rec.name, title: title,
                status: status, waitingFor: rec.waitingFor,
                updatedAt: Date(timeIntervalSince1970: (rec.updatedAt ?? rec.startedAt ?? 0) / 1000),
                transcriptURL: transcript,
                statusSince: rec.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
            // Only trust a captured request made around the time this prompt opened.
            if status == .waiting, let req = requests[rec.sessionId],
               req.date.timeIntervalSince(s.statusSince ?? .distantPast) > -10 {
                s.pendingTool = req.tool
            }
            // A resumed session can briefly have two records; keep the newest.
            if let existing = sessions[s.id], existing.updatedAt > s.updatedAt { continue }
            sessions[s.id] = s
        }
        let sorted = sessions.values.sorted {
            $0.status.sortRank != $1.status.sortRank ? $0.status.sortRank < $1.status.sortRank : $0.updatedAt > $1.updatedAt
        }
        return (sorted, updates)
    }

    nonisolated private static func loadRecent(excluding: Set<String>, cache: [String: TitleInfo]) -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var found: [(URL, Date)] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let id = f.deletingPathExtension().lastPathComponent
                guard !excluding.contains(id),
                      let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      m > cutoff else { continue }
                found.append((f, m))
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(40).compactMap { url, mtime in
            let (title, _) = title(for: url, cache: cache)
            guard let cwd = cwd(of: url) else { return nil }
            return Session(sessionId: url.deletingPathExtension().lastPathComponent, pid: nil, cwd: cwd,
                           name: nil, title: title, status: .ended, waitingFor: nil, updatedAt: mtime, transcriptURL: url)
        }
    }

    nonisolated private static func title(for url: URL?, cache: [String: TitleInfo]) -> (String?, TitleInfo?) {
        guard let url,
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return (nil, nil) }
        if let hit = cache[url.path], hit.mtime == mtime { return (hit.title, nil) }
        let (lines, _) = TailReader.read(url, from: nil, maxBytes: 256_000)
        var custom: String?
        var auto: String?
        for line in lines.reversed() {
            // Cheap pre-filter: only parse the title records.
            guard line.range(of: Data("-title\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["type"] as? String == "custom-title", let t = obj["customTitle"] as? String { custom = t; break }
            if auto == nil, obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String { auto = t }
        }
        // A custom name (/rename) wins over the auto title, which Claude keeps re-writing.
        var title = custom ?? auto
        if custom == nil, let cached = cache[url.path]?.title, cache[url.path]?.isCustom == true { title = cached }
        if title == nil { title = cache[url.path]?.title }
        return (title, TitleInfo(mtime: mtime, title: title, isCustom: custom != nil || cache[url.path]?.isCustom == true))
    }

    nonisolated private static func cwd(of url: URL) -> String? {
        let (lines, _) = TailReader.read(url, from: nil, maxBytes: 64_000)
        for line in lines.reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let c = obj["cwd"] as? String { return c }
        }
        return nil
    }

    nonisolated private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
