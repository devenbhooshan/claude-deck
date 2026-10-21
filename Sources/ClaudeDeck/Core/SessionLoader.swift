import Foundation

/// Reads Claude Code's session records (~/.claude/sessions) and transcripts (~/.claude/projects).
enum SessionLoader {
    /// A fresh read of one session's record, used right before typing into or answering it.
    static func record(pid: Int32) -> SessionRecord? {
        let url = ClaudePaths.sessions.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    static func loadLive(cache: [String: TitleInfo], alive: (Int32) -> Bool = isAlive,
                         tasks: () -> [Int32: [BackgroundTask]] = BackgroundTasks.snapshot) -> ([Session], [String: TitleInfo]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: ClaudePaths.sessions.path) else { return ([], [:]) }
        let requests = PendingRequests.load()
        var updates: [String: TitleInfo] = [:]
        var sessions: [String: Session] = [:]
        // The process list is read once, and only if some session runs a background task.
        var running: [Int32: [BackgroundTask]]?
        for file in files where file.hasSuffix(".json") {
            let url = ClaudePaths.sessions.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let rec = try? JSONDecoder().decode(SessionRecord.self, from: data),
                  !rec.isHeadless, alive(rec.pid) else { continue }
            let transcript = ClaudePaths.transcript(for: rec.sessionId, cwd: rec.cwd)
            let (title, update, replies) = details(for: transcript, cache: cache)
            if let transcript, let update { updates[transcript.path] = update }
            var background: [BackgroundTask] = []
            if rec.status == "shell" {
                if running == nil { running = tasks() }
                background = running?[rec.pid] ?? []
            }
            let status: SessionStatus = switch rec.status {
            case "waiting": .waiting
            case "busy": .busy
            case "shell": !background.isEmpty && background.allSatisfy(\.isServer) ? .idle : .background
            default: .idle
            }
            var s = Session(
                sessionId: rec.sessionId, pid: rec.pid, cwd: rec.cwd, name: rec.name, title: title,
                status: status, waitingFor: rec.waitingFor,
                updatedAt: Date(timeIntervalSince1970: (rec.updatedAt ?? rec.startedAt ?? 0) / 1000),
                transcriptURL: transcript,
                statusSince: rec.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                startedAt: rec.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, background: background, replies: replies)
            // Only trust a captured request made around the time this prompt opened.
            if status == .waiting, let req = requests[rec.sessionId],
               req.date.timeIntervalSince(s.statusSince ?? .distantPast) > -10 {
                s.pendingTool = req.tool
            }
            // A resumed session can briefly have two records; keep the newest.
            if let existing = sessions[s.id], existing.updatedAt > s.updatedAt { continue }
            sessions[s.id] = s
        }
        // A stable order: by start time (oldest first), never by status or activity, so a session
        // doesn't move when it starts or stops working. New sessions join at the end.
        return (sessions.values.sorted(by: startOrder), updates)
    }

    static func startOrder(_ a: Session, _ b: Session) -> Bool {
        (a.startedAt ?? .distantFuture, a.sessionId) < (b.startedAt ?? .distantFuture, b.sessionId)
    }

    static func loadRecent(excluding: Set<String>, cache: [String: TitleInfo], now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = now.addingTimeInterval(-7 * 86400)
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
            // Script/SDK runs (`claude -p`) aren't sessions you'd reopen.
            guard !isNonInteractive(url) else { return nil }
            let (title, _) = title(for: url, cache: cache)
            guard let cwd = cwd(of: url) else { return nil }
            return Session(sessionId: url.deletingPathExtension().lastPathComponent, pid: nil, cwd: cwd,
                           name: nil, title: title, status: .ended, waitingFor: nil, updatedAt: mtime, transcriptURL: url)
        }
    }

    static func title(for url: URL?, cache: [String: TitleInfo]) -> (String?, TitleInfo?) {
        let (title, info, _) = details(for: url, cache: cache)
        return (title, info)
    }

    /// The session's title and Claude's replies since your last message, from the transcript's tail
    /// (re-read only when the file changed; the info is nil when the cache was used).
    static func details(for url: URL?, cache: [String: TitleInfo]) -> (String?, TitleInfo?, [Date]) {
        guard let url,
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return (nil, nil, []) }
        if let hit = cache[url.path], hit.mtime == mtime { return (hit.title, nil, hit.replies) }
        let (lines, _) = TailReader.read(url, from: nil, maxBytes: 256_000)
        let replies = Self.replies(in: lines)
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
        return (title, TitleInfo(mtime: mtime, title: title, isCustom: custom != nil || cache[url.path]?.isCustom == true,
                                 replies: replies), replies)
    }

    /// When Claude wrote each reply (a message with text, not just tool calls) after the last thing
    /// you typed, oldest first. Notices Claude Code adds (background task results, command output)
    /// aren't you, and subagents' messages aren't replies to you.
    static func replies(in lines: [Data]) -> [Date] {
        var out: [Date] = []
        for line in lines.reversed() {
            let isUser = line.range(of: Data(#""type":"user""#.utf8)) != nil
            guard isUser || line.range(of: Data(#""type":"text""#.utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]
            let texts: [String] = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            switch obj["type"] as? String {
            case "user":
                let typed = texts.contains { !$0.hasPrefix("<task-notification>") && !$0.hasPrefix("<local-command-stdout>") }
                if typed { return out.reversed() }
            case "assistant":
                if texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                   let at = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFractions.date(from:)) {
                    out.append(at)
                }
            default: break
            }
        }
        return out.reversed()
    }

    /// Whether a transcript came from `claude -p` or the SDK (entrypoint "sdk-…") rather than you.
    static func isNonInteractive(_ url: URL) -> Bool {
        let (lines, _) = TailReader.read(url, from: nil, maxBytes: 64_000)
        for line in lines {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let entry = obj["entrypoint"] as? String {
                return entry.hasPrefix("sdk")
            }
        }
        return false
    }

    static func cwd(of url: URL) -> String? {
        let (lines, _) = TailReader.read(url, from: nil, maxBytes: 64_000)
        for line in lines.reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let c = obj["cwd"] as? String { return c }
        }
        return nil
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
