import Foundation

/// Something one session asks you to say in another, written as a code block marked
/// `send-to <session>`. Deck shows it as a card you can send with one click; your click is
/// what makes it yours, since a session rightly ignores approvals passed on by another one.
struct Handoff: Equatable, Hashable {
    /// The session's name as written.
    let target: String
    let text: String

    static let marker = "send-to"

    /// The session a code block's info string (```send-to supergrow) addresses, if it's a handoff.
    static func target(info: String?) -> String? {
        guard let info else { return nil }
        let parts = info.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == marker else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Every handoff in a reply, in order (not ones quoted inside a quote).
    static func all(in markdown: String) -> [Handoff] {
        Markdown.parse(markdown).compactMap { block in
            guard block.quoteDepth == 0, case .code(let code) = block.kind, let target = target(info: block.info) else { return nil }
            let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Handoff(target: target, text: text)
        }
    }

    /// Typed at Claude's prompt, `/` runs a command and `!` a shell command. Text another
    /// session wrote must never do either, so Deck only offers to copy it.
    var isTypeable: Bool { !(text.hasPrefix("/") || text.hasPrefix("!")) }

    /// Identifies it for "sent" and "dismissed".
    var key: String { target.lowercased() + "\u{1}" + text }
}

/// Addressing a session by name: `@supergrow merge it` in any message box goes to supergrow.
enum SessionAddress {
    /// How a session is written after `@`: its name in lower case, spaces as hyphens.
    static func token(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// `@name rest`: the name and the message, or nil if the draft isn't addressed.
    static func split(_ draft: String) -> (name: String, message: String)? {
        guard draft.hasPrefix("@"), let space = draft.firstIndex(where: \.isWhitespace) else { return nil }
        let name = String(draft[draft.index(after: draft.startIndex)..<space])
        let message = draft[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || message.isEmpty ? nil : (name, message)
    }

    /// The running session with that name (as `@token` or as written), only if exactly one has it.
    static func resolve(_ name: String, in sessions: [Session]) -> Session? {
        let wanted = token(name)
        let matches = sessions.filter { $0.isLive && token($0.displayTitle) == wanted }
        return matches.count == 1 ? matches[0] : nil
    }

    /// What's typed after a leading `@` while the name is still being typed, for the menu.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("@"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }
}

/// What's waiting on you across every session, in one list.
enum Inbox {
    enum Item: Equatable, Identifiable {
        /// A permission prompt or dialog.
        case prompt(Session)
        /// Claude finished its turn on a question.
        case question(Session, String)
        /// A message a session drafted for you to send to another.
        case handoff(from: Session, Handoff)

        var id: String {
            switch self {
            case .prompt(let s): "prompt:" + s.sessionId
            case .question(let s, _): "question:" + s.sessionId
            case let .handoff(s, h): "handoff:" + s.sessionId + ":" + h.key
            }
        }

        var session: Session {
            switch self {
            case .prompt(let s), .question(let s, _), .handoff(let s, _): s
            }
        }
    }

    /// Prompts first (they hold a session up), then handoffs, then questions. The coordinator's
    /// handoffs come before other sessions'.
    static func items(live: [Session], sent: Set<String>, dismissed: Set<String>, coordinator: String? = nil,
                      isAnswered: (Session) -> Bool = { _ in false }) -> [Item] {
        let prompts = live.filter { $0.status == .waiting && !isAnswered($0) }.map(Item.prompt)
        let byCoordinator = live.filter { $0.sessionId == coordinator } + live.filter { $0.sessionId != coordinator }
        let handoffs = byCoordinator.flatMap { s in
            s.handoffs.filter { !sent.contains($0.key) && !dismissed.contains($0.key) }.map { Item.handoff(from: s, $0) }
        }
        let questions = live.compactMap { s -> Item? in
            guard s.status == .idle, let q = question(in: s), !dismissed.contains(questionKey(s)) else { return nil }
            return .question(s, q)
        }
        return prompts + handoffs + questions
    }

    /// The question a session's last reply ends on: its last paragraph, if that asks something.
    static func question(in s: Session) -> String? {
        guard let reply = s.replyTexts.last else { return nil }
        let last = reply.components(separatedBy: "\n\n").last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let q = last?.trimmingCharacters(in: .whitespacesAndNewlines), q.hasSuffix("?") else { return nil }
        return q.count > 400 ? "…" + q.suffix(399) : q
    }

    /// A question stays dismissed until Claude writes again.
    static func questionKey(_ s: Session) -> String {
        "question:\(s.sessionId):\(s.replies.last?.timeIntervalSince1970 ?? 0)"
    }
}

/// A message one session sent another (Claude Code's SendMessage), or you sent from Deck.
struct CommsMessage: Equatable, Identifiable {
    let from: String
    let to: String
    let summary: String?
    let text: String
    let at: Date
    var id: String { "\(at.timeIntervalSince1970)|\(from)|\(to)|\(text.prefix(40))" }

    /// The messages a session sent, from lines of its transcript.
    static func sent(in lines: [Data], by sender: String) -> [CommsMessage] {
        var out: [CommsMessage] = []
        for line in lines where line.range(of: Data(#""name":"SendMessage""#.utf8)) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
                  let at = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFractions.date(from:)),
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content where block["name"] as? String == "SendMessage" {
                guard let input = block["input"] as? [String: Any], let to = input["to"] as? String,
                      let text = input["message"] as? String, !text.isEmpty else { continue }
                out.append(CommsMessage(from: sender, to: to, summary: input["summary"] as? String, text: text, at: at))
            }
        }
        return out
    }

    /// Everyone's messages, newest first, without repeats, keeping the newest `limit`.
    static func merge(_ lists: [[CommsMessage]], limit: Int = 500) -> [CommsMessage] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.sorted { $0.at > $1.at }.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// The newest message from each sender, newest first.
    static func latestBySender(_ messages: [CommsMessage]) -> [CommsMessage] {
        var seen = Set<String>()
        return messages.sorted { $0.at > $1.at }.filter { seen.insert($0.from).inserted }
    }
}
