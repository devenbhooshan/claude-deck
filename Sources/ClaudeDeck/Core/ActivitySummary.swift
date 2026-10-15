import Foundation

/// A PR's live details, from `gh pr view --json title,state,url,body,isDraft`.
struct PRInfo: Codable, Equatable {
    enum State: String, Codable { case open = "OPEN", merged = "MERGED", closed = "CLOSED", draft = "DRAFT" }

    var title: String
    var state: State
    var url: String?
    var body: String?
    var fetchedAt: Date

    static let fields = "title,state,url,body,isDraft"

    static func parse(_ json: String, at: Date = Date()) -> PRInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let title = obj["title"] as? String, let raw = obj["state"] as? String,
              var state = State(rawValue: raw) else { return nil }
        if state == .open, obj["isDraft"] as? Bool == true { state = .draft }
        let body = (obj["body"] as? String).map { String($0.prefix(600)) }.flatMap { $0.isEmpty ? nil : $0 }
        return PRInfo(title: title, state: state, url: obj["url"] as? String, body: body, fetchedAt: at)
    }

    /// Open PRs change; merged or closed ones don't.
    func isStale(now: Date = Date(), after: TimeInterval = 600) -> Bool {
        (state == .open || state == .draft) && now.timeIntervalSince(fetchedAt) > after
    }
}

/// One-line summaries, session recaps and daily digests written by Claude Haiku through the
/// `claude` CLI (your own login, no tools, nothing saved). Everything here is pure: building
/// prompts and checking replies. Replies that don't fit are dropped, never shown.
enum ActivitySummarizer {
    static let batchSize = 10
    static let maxSummary = 220

    /// `claude` arguments for one structured, tool-less, unsaved Haiku call.
    static func arguments(prompt: String, schema: String) -> [String] {
        ["-p", "--model", "haiku", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
         "--disable-slash-commands", "--output-format", "json", "--json-schema", schema, prompt]
    }

    static let itemsSchema = #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"summary":{"type":"string"}},"required":["id","summary"]}}},"required":["items"]}"#
    static let textSchema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#

    /// What the model sees about one event: what happened, the PR or ticket, and Claude's own words.
    static func describe(_ e: ActivityEvent, pr: PRInfo? = nil) -> [String: String] {
        var d: [String: String] = ["id": e.id, "event": [e.label, e.ref, e.repo.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")]
        if let title = pr?.title ?? e.title { d["title"] = title }
        if let detail = e.detail { d["detail"] = detail }
        if let body = pr?.body { d["description"] = String(body.prefix(300)) }
        if let n = e.narration { d["claude_said"] = n }
        return d
    }

    static func eventsPrompt(_ events: [ActivityEvent], pr: (ActivityEvent) -> PRInfo? = { _ in nil }) -> String {
        let items = events.map { describe($0, pr: pr($0)) }
        let json = String(data: try! JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), encoding: .utf8)!
        return """
            You write one-line activity summaries for a developer's log of what their coding agent did.
            For each event, write one sentence (at most 20 words) saying what was done and the outcome.
            Use only facts stated in the event's fields; never guess. No preamble, no "The agent".
            Return every id exactly as given.

            Events:
            \(json)
            """
    }

    /// id → summary, keeping only ids that were asked about and sensible, short answers.
    static func parseItems(_ output: String, ids: Set<String>) -> [String: String] {
        guard let items = structured(output)?["items"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            guard let id = item["id"] as? String, ids.contains(id),
                  let s = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s.count <= maxSummary else { continue }
            out[id] = s
        }
        return out
    }

    /// A 2–3 sentence recap of one session's activity.
    static func recapPrompt(title: String, events: [ActivityEvent], summaries: [String: String]) -> String {
        """
        Recap this coding session for its developer in 2-3 short sentences: what shipped, what was \
        reviewed, what's in progress. Use only these facts; mention PR and ticket numbers.

        Session: \(title)
        \(lines(events, summaries: summaries))
        """
    }

    /// A short standup-style digest of a day across sessions.
    static func digestPrompt(day: String, events: [ActivityEvent], summaries: [String: String],
                             sessionTitle: (String) -> String) -> String {
        let bySession = Dictionary(grouping: events, by: \.sessionId)
        let blocks = bySession.keys.sorted().map { id in
            "Session \"\(sessionTitle(id))\":\n" + lines(bySession[id]!, summaries: summaries)
        }.joined(separator: "\n\n")
        return """
            Write a short standup note of what the developer's coding agents did on \(day): a few \
            bullet points ("- "), grouped by outcome (shipped, reviewed, in progress), with PR and \
            ticket numbers. Use only these facts.

            \(blocks)
            """
    }

    static func lines(_ events: [ActivityEvent], summaries: [String: String]) -> String {
        events.map { e in
            let what = [e.label, e.ref, e.title].compactMap { $0 }.joined(separator: " ")
            let note = summaries[e.id] ?? e.quote
            return "- \(what)" + (note.map { ": \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    static func parseText(_ output: String) -> String? {
        guard let text = (structured(output)?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// The structured output of a `claude -p --output-format json --json-schema` run.
    static func structured(_ output: String) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              obj["is_error"] as? Bool != true else { return nil }
        if let s = obj["structured_output"] as? [String: Any] { return s }
        guard let result = obj["result"] as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
    }
}
