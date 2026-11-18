import Foundation

/// Something Deck tells a session it can't see for itself, typed into it a moment after you act,
/// several at once going in one message: handoffs you sent for it, changes you made to its board.
enum Receipt: Equatable {
    case handoff(Handoff)
    case board(BoardEdit)

    /// Text on one line in curly quotes, cut short past 80 characters.
    static func quote(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "“\(one.count > 80 ? one.prefix(79) + "…" : one)”"
    }

    /// The message: one sentence for handoffs, then one line per board change.
    static func text(for receipts: [Receipt]) -> String {
        var handoffs: [Handoff] = []
        var edits: [BoardEdit] = []
        for r in receipts {
            switch r {
            case .handoff(let h): handoffs.append(h)
            case .board(let e): edits.append(e)
            }
        }
        var lines: [String] = []
        if !handoffs.isEmpty { lines.append(Handoff.receipt(for: handoffs)) }
        if !edits.isEmpty {
            lines.append("[Claude Deck] I changed your task board. Show this in your next board:")
            lines += edits.map(\.line)
        }
        return lines.joined(separator: "\n")
    }
}

/// A change you made to a task on the coordinator's board. The board is the coordinator's, so
/// Deck never rewrites it: the change is typed to the coordinator as one line, and the task shows
/// as sent until a newer board reflects it.
struct BoardEdit: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        /// Mark done.
        case done
        /// A task waiting on you that you did yourself.
        case didIt
        case unblock
        /// Move to later (back to the to-do list).
        case later
        /// Hidden here for a while; the coordinator is told so it doesn't remind you.
        case snooze(hours: Int)
        /// Your answer to a task waiting on you.
        case answer(String)
    }

    let task: String
    let action: Action
    let at: Date
    var id: String { BoardEdit.key(task) + "\u{1}\(at.timeIntervalSince1970)" }

    /// A task's title compared loosely: case and spacing don't matter.
    static func key(_ title: String) -> String { title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// What happened to the task, in a few words.
    var what: String {
        switch action {
        case .done: "done"
        case .didIt: "done (I did it)"
        case .unblock: "unblocked"
        case .later: "move to later"
        case .snooze(let h): "snoozed for " + (h % 24 == 0 ? (h == 24 ? "a day" : "\(h / 24) days") : (h == 1 ? "an hour" : "\(h) hours"))
        case .answer(let a): "answer: " + a.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// The line typed to the coordinator: `Board: “Send invoice” → done (I did it)`.
    var line: String { "Board: \(Receipt.quote(task)) → \(what)" }

    /// What the task shows until the board catches up.
    var pendingLabel: String {
        switch action {
        case .didIt: "Sent: done"
        case .answer: "Sent: your answer"
        default: "Sent: " + what
        }
    }

    /// Whether a board has caught up, from the task's state on it (nil: it's gone from the board).
    func isReflected(by state: TaskItem.State?) -> Bool {
        guard let state else { return true }
        switch action {
        case .done: return state == .done
        case .didIt, .answer: return state != .you
        case .unblock: return state != .blocked
        case .later: return state == .todo || state == .done
        case .snooze: return true
        }
    }
}

/// Deck's own notes on a coordinator's board, kept in Application Support: changes you've sent
/// that its board doesn't show yet, tasks you've snoozed, and the last compaction it has seen.
struct BoardState: Codable, Equatable {
    var edits: [BoardEdit] = []
    /// Task key → when it comes back.
    var snoozed: [String: Date] = [:]
    /// The newest compaction already handled; nil until Deck first looks, "" if there was none.
    var compactionSeen: String? = nil

    /// How long a newer board may disagree before Deck stops showing the change as sent:
    /// the coordinator has seen it and decided otherwise, and its board wins.
    static let patience: TimeInterval = 15 * 60

    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck/board")

    static func fileURL(_ coordinator: String) -> URL { dir.appendingPathComponent(Decisions.safeName(coordinator) + ".json") }

    static func load(_ coordinator: String) -> BoardState {
        (try? Data(contentsOf: fileURL(coordinator))).flatMap { try? JSONDecoder().decode(BoardState.self, from: $0) } ?? BoardState()
    }

    func save(_ coordinator: String) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.fileURL(coordinator), options: .atomic)
    }

    /// Records a change: snoozes hide the task, the rest wait for the board to catch up.
    mutating func record(_ edit: BoardEdit) {
        if case .snooze(let h) = edit.action {
            snoozed[BoardEdit.key(edit.task)] = edit.at.addingTimeInterval(TimeInterval(h) * 3600)
        } else {
            edits.append(edit)
        }
    }

    /// Without changes a newer board shows (or has ignored for a while) and snoozes that ended.
    func reconciled(with board: TaskBoard?, now: Date) -> BoardState {
        var out = self
        out.snoozed = snoozed.filter { $0.value > now }
        guard let board else { return out }
        out.edits = edits.filter { e in
            guard board.at > e.at else { return true }
            let state = board.items.first { BoardEdit.key($0.title) == BoardEdit.key(e.task) }?.state
            return !e.isReflected(by: state) && board.at < e.at.addingTimeInterval(Self.patience)
        }
        return out
    }

    /// The newest change sent for a task that its board doesn't show yet.
    func pending(_ task: TaskItem) -> BoardEdit? { edits.last { BoardEdit.key($0.task) == BoardEdit.key(task.title) } }

    func isSnoozed(_ task: TaskItem, now: Date) -> Bool { (snoozed[BoardEdit.key(task.title)] ?? .distantPast) > now }

    /// The tasks the board shows: all but the snoozed ones.
    func visible(_ board: TaskBoard, now: Date) -> [TaskItem] { board.items.filter { !isSnoozed($0, now: now) } }

    /// How many shown tasks still need you: not ones you've sent "I did it", an answer or done for.
    func needsYou(_ board: TaskBoard, now: Date) -> Int {
        visible(board, now: now).filter { t in
            guard t.state == .you else { return false }
            switch pending(t)?.action {
            case .didIt, .answer, .done: return false
            default: return true
            }
        }.count
    }

    /// Whether to type the decisions in again: only for a compaction newer than the one already
    /// handled, never for ones from before Deck first looked. Also returns what to remember.
    static func compaction(latest: String?, seen: String?) -> (recap: Bool, seen: String) {
        guard let seen else { return (false, latest ?? "") }
        guard let latest, latest != seen else { return (false, seen) }
        return (true, latest)
    }
}

/// When Claude Code compacts a conversation it writes a `compact_boundary` system entry, then
/// the summary that replaces what came before.
enum Compaction {
    /// The newest compaction in lines of a transcript (the main conversation's), by its uuid.
    static func latest(in lines: [Data]) -> String? {
        lines.reversed().lazy.filter { $0.range(of: Data("compact_boundary".utf8)) != nil }.compactMap { line -> String? in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary",
                  obj["isSidechain"] as? Bool != true else { return nil }
            return obj["uuid"] as? String
        }.first
    }
}

/// A decision you made answering a task, kept so it survives the coordinator's compactions.
struct Decision: Equatable {
    let date: String
    let task: String
    let answer: String
}

/// The answers you gave on a coordinator's tasks, one markdown file per coordinator in
/// Application Support/ClaudeDeck/decisions, typed back in after it compacts.
enum Decisions {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck/decisions")

    static let header = "# Decisions\n\nAnswers you gave on the coordinator's tasks in Claude Deck.\n\n"

    /// A session id as a file name (anything else is replaced).
    static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    static func fileURL(_ coordinator: String) -> URL { dir.appendingPathComponent(safeName(coordinator) + ".md") }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// One line of the log: `- 2026-11-18 “Pick DB”: Postgres`.
    static func line(_ d: Decision) -> String {
        "- \(d.date) “\(d.task.split(whereSeparator: \.isWhitespace).joined(separator: " "))”: "
            + d.answer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The decisions in a log's text, in order.
    static func parse(_ text: String) -> [Decision] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let m = line.range(of: #"^- \d{4}-\d{2}-\d{2} “.*?”: "#, options: .regularExpression) else { return nil }
            let head = line[m]
            let date = String(head.dropFirst(2).prefix(10))
            let task = String(head.dropFirst(14).dropLast(3))
            return Decision(date: date, task: task, answer: String(line[m.upperBound...]))
        }
    }

    static func load(_ coordinator: String) -> [Decision] {
        parse((try? String(contentsOf: fileURL(coordinator), encoding: .utf8)) ?? "")
    }

    static func append(_ d: Decision, to coordinator: String) {
        let old = (try? String(contentsOf: fileURL(coordinator), encoding: .utf8)) ?? header
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (old + line(d) + "\n").write(to: fileURL(coordinator), atomically: true, encoding: .utf8)
    }

    /// What's typed into the coordinator after it compacts, or nil if there's nothing to say.
    static func recap(_ decisions: [Decision]) -> String? {
        decisions.isEmpty ? nil : (["[Claude Deck] Decisions so far:"] + decisions.map(line)).joined(separator: "\n")
    }
}
