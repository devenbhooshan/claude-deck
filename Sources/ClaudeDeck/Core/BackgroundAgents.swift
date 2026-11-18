import Foundation

/// Where a background session's job stands, as `claude agents` reports it.
enum AgentState: String {
    case working, blocked, done, failed, stopped

    var label: String {
        switch self {
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// One row of `claude agents --json --all`: every session, running or not. A running one has a
/// pid and a status; a background one (kind "background") adds its short job id and its state.
struct AgentEntry: Decodable, Equatable {
    let cwd: String
    var kind: String? = nil
    var startedAt: Double? = nil
    var pid: Int32? = nil
    var status: String? = nil
    var sessionId: String? = nil
    var name: String? = nil
    /// The job id, for `claude attach / stop / rm`.
    var id: String? = nil
    var state: String? = nil

    var isBackground: Bool { kind == "background" || kind == "bg" }
    var agentState: AgentState? { state.flatMap(AgentState.init(rawValue:)) }
}

/// Background sessions (`claude --bg`), listed with `claude agents`. Claude Code's job files are
/// documented as unstable, so only the command's JSON is read.
enum BackgroundAgents {
    static let listArguments = ["agents", "--json", "--all"]
    /// How often to list them: the command takes about a tenth of a second.
    static let pollInterval: TimeInterval = 5

    /// The command's output, or nil when it isn't the JSON list (an old Claude Code, an error).
    static func parse(_ output: String) -> [AgentEntry]? {
        guard let start = output.firstIndex(of: "[") else { return nil }
        return try? JSONDecoder().decode([AgentEntry].self, from: Data(output[start...].utf8))
    }

    /// The running sessions with what `claude agents` knows about the background ones (job id and
    /// state; a session it calls background is one, whatever its record says), and the background
    /// sessions that have exited, as ended sessions whose transcript can be read (with the title
    /// cache's updates for those transcripts).
    static func merge(live: [Session], agents: [AgentEntry], cache: [String: TitleInfo])
        -> (live: [Session], exited: [Session], updates: [String: TitleInfo]) {
        let background = agents.filter(\.isBackground)
        let byId = Dictionary(background.compactMap { a in a.sessionId.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        let merged = live.map { s -> Session in
            guard let a = byId[s.sessionId] else { return s }
            var s = s
            s.isBackground = true
            s.jobId = a.id ?? s.jobId
            s.agentState = a.agentState
            return s
        }
        let liveIds = Set(live.map(\.sessionId))
        var seen = Set<String>()
        var updates: [String: TitleInfo] = [:]
        let exited = background.compactMap { a -> Session? in
            // A row with a pid is running: its record shows it (or will, on the next look).
            guard a.pid == nil, let id = a.sessionId, !liveIds.contains(id), seen.insert(id).inserted else { return nil }
            let transcript = ClaudePaths.transcript(for: id, cwd: a.cwd)
            let started = a.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            let changed = transcript.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            let (title, update) = SessionLoader.title(for: transcript, cache: cache)
            if let transcript, let update { updates[transcript.path] = update }
            return Session(sessionId: id, pid: nil, cwd: a.cwd, name: a.name, title: title,
                           status: .ended, waitingFor: nil, updatedAt: changed ?? started ?? .distantPast, transcriptURL: transcript,
                           startedAt: started, isBackground: true, jobId: a.id, agentState: a.agentState)
        }
        return (merged, exited.sorted { $0.updatedAt > $1.updatedAt }, updates)
    }

    /// Each background session's state, by session id, to compare with the next look.
    static func states(_ sessions: [Session]) -> [String: AgentState] {
        Dictionary(sessions.compactMap { s in s.agentState.map { (s.sessionId, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Fleet news from background sessions' state changes: done is finished, failed ended
    /// unexpectedly, blocked waits on you. The first look (no `old`) is only a baseline.
    static func events(from old: [String: AgentState]?, to sessions: [Session], excluded: Set<String> = []) -> [FleetEvent] {
        guard let old else { return [] }
        return sessions.compactMap { s in
            guard let now = s.agentState, let was = old[s.sessionId], was != now, !excluded.contains(s.sessionId) else { return nil }
            switch now {
            case .done: return .finished(s)
            case .failed: return .ended(s, unexpected: true)
            case .blocked: return .waiting(s)
            case .working, .stopped: return nil
            }
        }
    }
}
