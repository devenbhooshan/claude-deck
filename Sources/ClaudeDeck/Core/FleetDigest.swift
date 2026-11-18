import Foundation

/// Something that changed in the fleet since Deck last looked, for the coordinator to hear about.
enum FleetEvent: Equatable {
    /// Claude finished its turn (busy → idle).
    case finished(Session)
    /// A permission prompt or dialog opened.
    case waiting(Session)
    /// Working, but nothing written to its transcript since `since`.
    case stuck(Session, since: Date)
    /// The same conversation came back in a new process (Deck's Restart, or a resume).
    case restarted(Session)
    /// Its process is gone. `unexpected`: it went while working or at a prompt, and not by Deck's End.
    case ended(Session, unexpected: Bool)
    case started(Session)
    /// The session's CI or deploy changed, in a few words ("CI failed on #412").
    case ciFlipped(Session, String)

    var session: Session {
        switch self {
        case .finished(let s), .waiting(let s), .stuck(let s, _), .restarted(let s), .ended(let s, _), .started(let s),
             .ciFlipped(let s, _): s
        }
    }

    /// Events with the same key replace each other in a batch: only the newest state is news.
    /// CI is kept apart from the session's own state.
    var key: String {
        if case .ciFlipped = self { return "ci:" + session.sessionId }
        return session.sessionId
    }
}

/// The fleet as Deck saw it at one poll.
struct FleetSnapshot: Equatable {
    var sessions: [Session] = []
    /// Sessions that were stuck then, by id: stuck is news only when a session becomes stuck.
    var stuck: Set<String> = []
}

/// A change-only feed of the fleet's state for the coordinator: the difference between two polls,
/// as events, batched and typed into the coordinator as one line.
enum FleetDigest {
    static let defaultStuckMinutes = 10
    /// At most one line this often.
    static let interval: TimeInterval = 120

    /// Deck's own doings, which change how a difference reads.
    struct Context {
        /// Never reported: the coordinator itself and muted sessions.
        var excluded: Set<String> = []
        /// Sessions Deck's End closed: ended, as asked.
        var endedByDeck: Set<String> = []
        /// Sessions Deck's Restart brought back under a new id: restarted, not started.
        var restartedByDeck: Set<String> = []
        /// Ids a restart replaced: not reported as ended.
        var replaced: Set<String> = []
    }

    /// When a working session last wrote anything, if that was at least `threshold` ago and no
    /// background command (other than a server) is running that would explain the silence.
    static func stuckSince(_ s: Session, now: Date, threshold: TimeInterval) -> Date? {
        guard s.isLive, s.status == .busy, s.background.allSatisfy(\.isServer),
              let quiet = [s.activeAt, s.statusSince].compactMap({ $0 }).max(),
              now.timeIntervalSince(quiet) >= threshold else { return nil }
        return quiet
    }

    static func snapshot(_ live: [Session], now: Date, threshold: TimeInterval) -> FleetSnapshot {
        FleetSnapshot(sessions: live, stuck: Set(live.filter { stuckSince($0, now: now, threshold: threshold) != nil }.map(\.sessionId)))
    }

    /// What changed from `old` to `new`. The first poll (no `old`) is only a baseline.
    static func events(from old: FleetSnapshot?, to new: FleetSnapshot, now: Date, threshold: TimeInterval,
                       context: Context = Context()) -> [FleetEvent] {
        guard let old else { return [] }
        let before = Dictionary(old.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [FleetEvent] = []
        for s in new.sessions where !context.excluded.contains(s.sessionId) {
            guard let was = before[s.sessionId] else {
                out.append(context.restartedByDeck.contains(s.sessionId) ? .restarted(s) : .started(s))
                continue
            }
            if was.pid != s.pid {
                out.append(.restarted(s))
                continue
            }
            if s.status == .waiting && was.status != .waiting {
                out.append(.waiting(s))
            } else if s.status == .idle && was.status == .busy {
                out.append(.finished(s))
            }
            if !old.stuck.contains(s.sessionId), let since = stuckSince(s, now: now, threshold: threshold) {
                out.append(.stuck(s, since: since))
            }
        }
        let still = Set(new.sessions.map(\.sessionId))
        for was in old.sessions where !still.contains(was.sessionId) && !context.excluded.contains(was.sessionId)
            && !context.replaced.contains(was.sessionId) {
            let cutShort = was.status == .busy || was.status == .waiting
            out.append(.ended(was, unexpected: cutShort && !context.endedByDeck.contains(was.sessionId)))
        }
        return out
    }

    /// Adds new events to a waiting batch: a newer event about the same thing replaces the older one.
    static func merge(_ pending: [FleetEvent], _ new: [FleetEvent]) -> [FleetEvent] {
        var out = pending
        for e in new {
            if let i = out.firstIndex(where: { $0.key == e.key }) { out[i] = e } else { out.append(e) }
        }
        return out
    }

    /// The batch as it stands now: events no longer true are dropped (a prompt you've since
    /// answered, a session that came back), and the rest carry the session as it is now.
    /// `live` may include background sessions that have exited (not running, with their job state).
    static func current(_ events: [FleetEvent], live: [Session], now: Date, threshold: TimeInterval) -> [FleetEvent] {
        events.compactMap { e in
            let s = live.first { $0.sessionId == e.session.sessionId }
            switch e {
            // A background session's job state counts too: it can be done (or blocked) after it has exited.
            case .finished: return s.flatMap { $0.status == .idle || $0.agentState == .done ? .finished($0) : nil }
            case .waiting: return s.flatMap { $0.status == .waiting || $0.agentState == .blocked ? .waiting($0) : nil }
            case .stuck: return s.flatMap { s in stuckSince(s, now: now, threshold: threshold).map { .stuck(s, since: $0) } }
            case .restarted: return s.map(FleetEvent.restarted)
            case .started: return s.map(FleetEvent.started)
            case .ended: return s?.isLive == true ? nil : e
            case .ciFlipped(_, let text): return .ciFlipped(s ?? e.session, text)
            }
        }
    }

    /// The whole batch on one line, or nil when there's nothing to say:
    /// `[Claude Deck] Fleet: api finished · web waiting on you (Bash) · search stuck 12m`.
    static func line(_ events: [FleetEvent], now: Date) -> String? {
        guard !events.isEmpty else { return nil }
        return "[Claude Deck] Fleet: " + events.map { phrase($0, now: now) }.joined(separator: " · ")
    }

    static func phrase(_ e: FleetEvent, now: Date) -> String {
        let name = e.session.displayTitle
        switch e {
        case .finished: return "\(name) finished"
        case .waiting(let s):
            return "\(name) waiting on you" + ((s.pendingTool?.name ?? s.waitingFor).map { " (\($0))" } ?? "")
        case .stuck(_, let since): return "\(name) stuck \(minutes(since: since, now: now))m"
        case .restarted: return "\(name) restarted"
        case .ended(_, let unexpected): return unexpected ? "\(name) ended unexpectedly" : "\(name) ended"
        case .started: return "\(name) started"
        case .ciFlipped(_, let text): return "\(name) \(text)"
        }
    }

    /// A CI flip in a few words, for `ciFlipped`: "PR #412 checks failed".
    static func ciText(_ flip: CIFlip, pr: Int?) -> String {
        let checks = pr.map { "PR #\($0) checks" } ?? "checks"
        switch flip {
        case .wentGreen: return "\(checks) passed"
        case .wentRed: return "\(checks) failed"
        case .deployed: return "deployed"
        case .deployFailed: return "deploy failed"
        }
    }

    static func minutes(since: Date, now: Date) -> Int { max(0, Int(now.timeIntervalSince(since)) / 60) }

    /// Whether to type the batch now: there is one, the coordinator is running and at its prompt
    /// (not working, no prompt open), and the last line went at least `interval` ago.
    static func shouldDeliver(_ batch: [FleetEvent], coordinator: Session?, lastSent: Date?, now: Date,
                              interval: TimeInterval = interval) -> Bool {
        guard !batch.isEmpty, let c = coordinator, c.isLive, c.status == .idle || c.status == .background else { return false }
        return lastSent.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}
