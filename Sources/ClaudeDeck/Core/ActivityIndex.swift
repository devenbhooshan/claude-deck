import Foundation

/// One transcript's indexing progress: how far it's been read, and what was found so far.
struct SessionActivity: Codable {
    var extractor: ActivityExtractor
    var path: String
    var offset: UInt64 = 0
    /// Saved with the index; a different version (how events are found changed) re-reads it.
    var version = ActivityIndex.version

    var sessionId: String { extractor.sessionId }
    var events: [ActivityEvent] { extractor.events }
}

/// Keeps an activity index of every transcript, reading only what's new since last time and
/// saving its progress, so even hundreds of MB of history stay quick. Events outlive their
/// transcript: Claude Code deletes old transcripts, but their history stays in the index.
enum ActivityIndex {
    /// Where the index is kept. Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck/activity")

    static let chunkSize = 8 << 20
    /// Bump when extraction changes, so saved progress is thrown away and transcripts re-read.
    static let version = 2

    /// Reads whatever was appended since last time. A file that shrank was rewritten, so it's
    /// read again from the start. Returns whether anything new was read.
    @discardableResult
    static func update(_ state: inout SessionActivity) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: state.path) else { return false }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        if size < state.offset {
            state.extractor = ActivityExtractor(sessionId: state.sessionId)
            state.offset = 0
        }
        guard size > state.offset else { return false }
        try? handle.seek(toOffset: state.offset)
        var carry = Data()
        var offset = state.offset
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var buffer = carry + chunk
            // Only complete lines; the rest waits for the next chunk (or the next update).
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else { carry = buffer; continue }
            let complete = buffer[buffer.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                state.extractor.ingest(Data(line))
            }
            offset += UInt64(complete.count)
            buffer = Data(buffer[buffer.index(after: lastNewline)...])
            carry = buffer
        }
        let changed = offset != state.offset
        state.offset = offset
        return changed
    }

    /// Every transcript on disk, as (session id, path).
    static func transcripts() -> [(id: String, path: String)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: ClaudePaths.projects.path) else { return [] }
        return dirs.flatMap { d -> [(id: String, path: String)] in
            let folder = ClaudePaths.projects.appendingPathComponent(d)
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            return files.filter { $0.hasSuffix(".jsonl") }.map {
                (String($0.dropLast(6)), folder.appendingPathComponent($0).path)
            }
        }
    }

    /// Brings `index` up to date with every transcript (new ones included) and returns the ids
    /// whose events changed, so only those are saved.
    static func refresh(_ index: inout [String: SessionActivity]) -> Set<String> {
        var changed = Set<String>()
        for t in transcripts() {
            var state = index[t.id] ?? SessionActivity(extractor: ActivityExtractor(sessionId: t.id), path: t.path)
            state.path = t.path
            if update(&state) || index[t.id] == nil { changed.insert(t.id) }
            index[t.id] = state
        }
        return changed
    }

    // MARK: - Saving

    static func load() -> [String: SessionActivity] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var index: [String: SessionActivity] = [:]
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(SessionActivity.self, from: data),
               s.version == version {
                index[s.sessionId] = s
            }
        }
        return index
    }

    static func save(_ states: [SessionActivity]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in states {
            guard Safety.isSessionId(s.sessionId), let data = try? JSONEncoder().encode(s) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(s.sessionId).json"), options: .atomic)
        }
    }

    // MARK: - Browsing

    enum Filter: String, CaseIterable {
        case all = "All", prs = "PRs", tickets = "Tickets", screenshots = "Screenshots"
    }

    /// Newest first, narrowed by kind and by a search over refs, titles, details, narration and
    /// the session's name.
    static func browse(_ events: [ActivityEvent], filter: Filter = .all, query: String = "",
                       sessionTitle: (String) -> String? = { _ in nil }) -> [ActivityEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            switch filter {
            case .all: true
            case .prs: e.isPR
            case .tickets: e.isTicket
            case .screenshots: e.kind == .screenshot
            }
        }.filter { e in
            guard !q.isEmpty else { return true }
            let hay = [e.ref, e.repo, e.title, e.detail, e.narration, e.label, sessionTitle(e.sessionId)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return q.split(separator: " ").allSatisfy { hay.contains($0) }
        }.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    /// Groups (already sorted) events by calendar day, keeping their order.
    static func byDay(_ events: [ActivityEvent], calendar: Calendar = .current) -> [(day: Date, events: [ActivityEvent])] {
        var groups: [(day: Date, events: [ActivityEvent])] = []
        for e in events {
            let day = e.at.map { calendar.startOfDay(for: $0) } ?? .distantPast
            if groups.last?.day == day { groups[groups.count - 1].events.append(e) } else { groups.append((day, [e])) }
        }
        return groups
    }

    /// "Today", "Yesterday", or the date.
    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        if day == .distantPast { return "Earlier" }
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: day)
    }
}
