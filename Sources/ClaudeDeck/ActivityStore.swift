import AppKit
import CoreGraphics
import Foundation
import Observation

/// What every session did with PRs, tickets and screenshots: indexed from the transcripts in the
/// background, with live PR status from `gh` and (optionally) one-line summaries from Claude Haiku.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var index: [String: SessionActivity] = [:]
    /// Every event, newest first (rebuilt when the index changes).
    private(set) var all: [ActivityEvent] = []
    private(set) var prInfo: [String: PRInfo] = [:]
    private(set) var summaries: [String: String] = [:]
    private(set) var recaps: [String: Recap] = [:]
    private(set) var indexing = false
    private(set) var loaded = false
    private(set) var summarizing = false
    private(set) var recapping: Set<String> = []
    private(set) var digest: Digest?
    private(set) var digestLoading = false
    var lastError: String?

    /// One-line AI summaries (Claude Haiku via your `claude` login). On by default; off stops all calls.
    var aiSummaries: Bool = UserDefaults.standard.object(forKey: "activityAISummaries") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(aiSummaries, forKey: "activityAISummaries")
            if aiSummaries { pumpSummaries() }
        }
    }

    struct Recap: Codable { var text: String; var at: Date }
    struct Digest { var day: String; var text: String }

    private var timer: Timer?
    private var lookingUp: Set<String> = []
    private var failedLookups: [String: Date] = [:]
    private var summaryQueue: [String] = []
    private var attempted: Set<String> = []

    /// Most summary calls a day, so a huge backlog can't eat into your plan.
    static let dailyCallLimit = 150
    /// Seconds without keyboard or mouse input before a summary call starts (not mid-typing).
    static let idleSeconds: Double = 3

    private nonisolated static var storeDir: URL { ActivityIndex.dir.deletingLastPathComponent() }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        Task.detached(priority: .utility) {
            let loadedIndex = ActivityIndex.load()
            let extras = Self.loadExtras()
            await MainActor.run {
                self.index = loadedIndex
                self.prInfo = extras.prs
                self.summaries = extras.summaries
                self.recaps = extras.recaps
                self.rebuild()
                self.loaded = true
                self.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.pumpSummaries()
            }
        }
    }

    /// Reads whatever the transcripts gained since last time.
    func refresh() {
        guard loaded, !indexing else { return }
        indexing = true
        let snapshot = index
        Task.detached(priority: .utility) {
            var idx = snapshot
            let changed = ActivityIndex.refresh(&idx)
            ActivityIndex.save(changed.compactMap { idx[$0] })
            let updated = idx
            await MainActor.run {
                self.indexing = false
                guard !changed.isEmpty else { return }
                self.index = updated
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        all = ActivityIndex.browse(index.values.flatMap(\.events))
    }

    // MARK: - Lookups

    func events(for sessionId: String) -> [ActivityEvent] {
        (index[sessionId]?.events ?? []).sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    func current(for sessionId: String) -> CurrentWork? {
        guard let s = index[sessionId] else { return nil }
        return CurrentWork.of(events: s.events, branch: s.extractor.branch)
    }

    func sessionTitle(_ sessionId: String) -> String? {
        index[sessionId]?.extractor.title
    }

    func sessionFolder(_ sessionId: String) -> String? {
        index[sessionId]?.extractor.cwd
    }

    /// Where `gh` should look the PR up: its repo if known, else the folder the command ran in.
    private func lookupKey(_ e: ActivityEvent) -> String? {
        guard let n = e.number else { return nil }
        return "\(e.repo ?? e.dir ?? sessionFolder(e.sessionId) ?? "")#\(n)"
    }

    func pr(for e: ActivityEvent) -> PRInfo? {
        lookupKey(e).flatMap { prInfo[$0] }
    }

    /// The best title we have: the event's, the live PR's, or for a ticket, one found elsewhere.
    func title(for e: ActivityEvent) -> String? {
        if let t = e.title { return t }
        if let p = pr(for: e) { return p.title }
        guard let ticket = e.ticket else { return nil }
        return all.first { $0.ticket == ticket && $0.title != nil }?.title
            ?? prInfo.values.first { $0.title.contains(ticket) }?.title
    }

    func url(for e: ActivityEvent) -> URL? {
        let ticketURL = e.ticket.flatMap { ActivityEvent.linearURL(for: $0, in: all) }
        return (pr(for: e)?.url ?? e.url ?? ticketURL).flatMap(URL.init(string:))
    }

    /// The repo to show: named in the event, or learned from `gh`.
    func repo(for e: ActivityEvent) -> String? {
        if let r = e.repo { return r }
        guard let url = pr(for: e)?.url, let m = Rx.first(#"github\.com/([\w.-]+/[\w.-]+)/pull"#, in: url) else { return nil }
        return m[1]
    }

    // MARK: - Showing events (fetches PR status and queues summaries)

    /// Called as events come on screen: look up their PRs and summarize them.
    func appeared(_ events: [ActivityEvent]) {
        for e in events where e.number != nil { lookUp(e) }
        guard aiSummaries else { return }
        for e in events where summaries[e.id] == nil && !attempted.contains(e.id) && !summaryQueue.contains(e.id) {
            summaryQueue.append(e.id)
        }
        pumpSummaries()
    }

    private func lookUp(_ e: ActivityEvent) {
        guard let key = lookupKey(e), !lookingUp.contains(key) else { return }
        if let info = prInfo[key], !info.isStale() { return }
        if let failed = failedLookups[key], Date().timeIntervalSince(failed) < 3600 { return }
        guard lookingUp.count < 3 else { return }
        lookingUp.insert(key)
        var args = ["pr", "view", String(e.number!), "--json", PRInfo.fields]
        if let repo = e.repo { args += ["--repo", repo] }
        let dir = e.dir ?? sessionFolder(e.sessionId) ?? NSHomeDirectory()
        Task.detached(priority: .utility) {
            let result = ClaudeRunner.gh(args, in: dir)
            let info = (try? result.get()).flatMap { PRInfo.parse($0) }
            await MainActor.run {
                self.lookingUp.remove(key)
                if let info {
                    self.prInfo[key] = info
                    self.saveExtras()
                } else {
                    self.failedLookups[key] = Date()
                }
            }
        }
    }

    // MARK: - AI summaries

    private func pumpSummaries() {
        guard aiSummaries, !summarizing, !summaryQueue.isEmpty, Self.callsToday() < Self.dailyCallLimit else { return }
        // Only while you're away from the keyboard, so it never competes with your own sessions.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.idleSeconds else { return }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let batch = summaryQueue.prefix(ActivitySummarizer.batchSize).compactMap { byId[$0] }
        summaryQueue.removeFirst(min(ActivitySummarizer.batchSize, summaryQueue.count))
        guard !batch.isEmpty else { return pumpSummaries() }
        for e in batch { attempted.insert(e.id) }
        summarizing = true
        Self.countCall()
        let prompt = ActivitySummarizer.eventsPrompt(batch, pr: { self.pr(for: $0) })
        let ids = Set(batch.map(\.id))
        Task.detached(priority: .utility) {
            let out = (try? ClaudeRunner.run(ActivitySummarizer.arguments(prompt: prompt, schema: ActivitySummarizer.itemsSchema),
                                             in: NSHomeDirectory(), timeout: 120).get()) ?? ""
            let found = ActivitySummarizer.parseItems(out, ids: ids)
            await MainActor.run {
                self.summarizing = false
                for (id, s) in found { self.summaries[id] = s }
                if !found.isEmpty { self.saveExtras() }
                self.pumpSummaries()
            }
        }
    }

    /// A short recap of one session, on request.
    func recap(_ sessionId: String, title: String) {
        guard !recapping.contains(sessionId) else { return }
        let events = Array(events(for: sessionId).prefix(40).reversed())
        guard !events.isEmpty else { return }
        recapping.insert(sessionId)
        Self.countCall()
        let prompt = ActivitySummarizer.recapPrompt(title: title, events: events, summaries: summaries)
        Task.detached(priority: .userInitiated) {
            let out = (try? ClaudeRunner.run(ActivitySummarizer.arguments(prompt: prompt, schema: ActivitySummarizer.textSchema),
                                             in: NSHomeDirectory(), timeout: 120).get()) ?? ""
            let text = ActivitySummarizer.parseText(out)
            await MainActor.run {
                self.recapping.remove(sessionId)
                if let text {
                    self.recaps[sessionId] = Recap(text: text, at: Date())
                    self.saveExtras()
                } else {
                    self.lastError = "Couldn't write a recap right now. Try again in a moment."
                }
            }
        }
    }

    /// A standup-style note of one day across sessions, on request.
    func makeDigest(day: String, events: [ActivityEvent], sessionTitle: @escaping (String) -> String) {
        guard !digestLoading, !events.isEmpty else { return }
        digestLoading = true
        Self.countCall()
        let prompt = ActivitySummarizer.digestPrompt(day: day, events: Array(events.prefix(80).reversed()),
                                                     summaries: summaries, sessionTitle: sessionTitle)
        Task.detached(priority: .userInitiated) {
            let out = (try? ClaudeRunner.run(ActivitySummarizer.arguments(prompt: prompt, schema: ActivitySummarizer.textSchema),
                                             in: NSHomeDirectory(), timeout: 120).get()) ?? ""
            let text = ActivitySummarizer.parseText(out)
            await MainActor.run {
                self.digestLoading = false
                if let text {
                    self.digest = Digest(day: day, text: text)
                } else {
                    self.lastError = "Couldn't write the digest right now. Try again in a moment."
                }
            }
        }
    }

    func clearDigest() { digest = nil }

    // MARK: - Saving (summaries, PR status, recaps)

    private struct Extras: Codable {
        var prs: [String: PRInfo] = [:]
        var summaries: [String: String] = [:]
        var recaps: [String: Recap] = [:]
    }

    private nonisolated static func loadExtras() -> Extras {
        let url = storeDir.appendingPathComponent("activity-extras.json")
        guard let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode(Extras.self, from: data) else { return Extras() }
        return e
    }

    private func saveExtras() {
        let extras = Extras(prs: prInfo, summaries: summaries, recaps: recaps)
        let url = Self.storeDir.appendingPathComponent("activity-extras.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(extras) { try? data.write(to: url, options: .atomic) }
        }
    }

    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "activityCalls-" + f.string(from: Date())
    }

    static func callsToday() -> Int { UserDefaults.standard.integer(forKey: dayKey()) }

    private static func countCall() {
        UserDefaults.standard.set(callsToday() + 1, forKey: dayKey())
    }
}
