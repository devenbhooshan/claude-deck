import Foundation

/// The messages you typed into your sessions, to suggest snippets for what you keep retyping.
enum SnippetHistory {
    struct Message: Equatable {
        let text: String
        let session: String
        let at: Date?
    }

    /// A line or sentence you typed in more than one message.
    struct Phrase: Equatable {
        let text: String
        var count = 0
        var sessions: Set<String> = []
    }

    private static let marker = Data(#""type":"user""#.utf8)

    /// What you typed in transcripts from the last `days` days, newest first: not tool results,
    /// subagent prompts, slash commands, Deck's own lines or long pastes.
    static func messages(days: Int = 30, now: Date = Date()) -> [Message] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var out: [Message] = []
        let dirs = (try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let session = file.deletingPathExtension().lastPathComponent
                for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          obj["type"] as? String == "user", obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
                          let content = (obj["message"] as? [String: Any])?["content"] else { continue }
                    let at = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFractions.date(from:))
                    if let at, at < cutoff { continue }
                    let raw = content as? String
                        ?? (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                            .joined(separator: "\n")
                    if let text = typed(raw) { out.append(Message(text: text, session: session, at: at)) }
                }
            }
        }
        func when(_ m: Message) -> Date { m.at ?? .distantPast }
        return out.sorted { when($0) > when($1) }
    }

    /// The text as you typed it, or nil for what you didn't type yourself (or pasted in bulk).
    static func typed(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let notYours = ["/", "<", "[Claude Deck]", "[Request interrupted", "Caveat:"]
        guard !text.isEmpty, text.count <= 2000, !notYours.contains(where: text.hasPrefix) else { return nil }
        return text
    }

    /// Lowercased, single-spaced, without closing punctuation: "Keep it SHORT." and "keep it short" match.
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
    }

    /// Lines and sentences you typed in more than one message, most often first: the strongest
    /// hint of something worth a snippet.
    static func repeated(_ messages: [Message], limit: Int = 40) -> [Phrase] {
        var byKey: [String: Phrase] = [:]
        for m in messages {
            var seen = Set<String>()
            let pieces = m.text.split(separator: "\n").flatMap {
                $0.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression).split(separator: "\n")
            }
            for piece in pieces {
                let shown = piece.trimmingCharacters(in: .whitespaces)
                let key = normalize(shown)
                guard key.count >= 10, seen.insert(key).inserted else { continue }
                var p = byKey[key] ?? Phrase(text: String(PolicyHistory.redact(shown).prefix(200)))
                p.count += 1
                p.sessions.insert(m.session)
                byKey[key] = p
            }
        }
        return Array(byKey.values.filter { $0.count > 1 }.sorted { ($0.count, $1.text) > ($1.count, $0.text) }.prefix(limit))
    }

    /// How many of `messages` contain `phrase` (as normalized), and in how many sessions.
    static func uses(of phrase: String, in messages: [Message]) -> (count: Int, sessions: Int) {
        let key = normalize(phrase)
        guard key.count >= 6 else { return (0, 0) }
        let found = messages.filter { normalize($0.text).contains(key) }
        return (found.count, Set(found.map(\.session)).count)
    }
}

/// Snippets Claude suggests from what you keep typing, for you to add.
enum SnippetSuggestions {
    struct Suggestion: Equatable, Identifiable {
        var snippet: Snippet
        /// Why it's worth having, citing what you typed.
        var why: String
        /// What you typed that it replaces, and how often.
        var phrase: String
        var count: Int
        var sessions: Int
        var id: String { snippet.id }
    }

    static let schema = #"{"type":"object","properties":{"suggestions":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"text":{"type":"string"},"phrase":{"type":"string"},"why":{"type":"string"}},"required":["name","text","phrase","why"]}}},"required":["suggestions"]}"#

    static func prompt(messages: [SnippetHistory.Message], days: Int, existing: [Snippet], sample: Int = 150) -> String {
        let phrases = SnippetHistory.repeated(messages).map { "- \"\($0.text)\"  (\($0.count)× in \($0.sessions.count) sessions)" }
        let recent = messages.prefix(sample).map {
            "- " + PolicyHistory.redact(String($0.text.prefix(300))).replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        let have = existing.map { "- \($0.name): \($0.text.replacingOccurrences(of: "\n", with: " "))" }
        return """
            You help a developer stop retyping the same instructions to their coding agent (Claude Code). \
            A snippet is a saved piece of text they insert by typing /s and its name, or add to every message.

            Below are lines they typed in more than one message over the last \(days) days (with counts), \
            a sample of their recent messages, and the snippets they already have.

            Suggest up to 6 NEW snippets for instructions they really do repeat: style and tone ("keep it short"), \
            working rules ("run the tests before you say it's done"), recurring requests ("check today's standup \
            on slack"). Never suggest one-off tasks, anything about a single bug or file, or what an existing \
            snippet already covers.

            "text" is the snippet as they'd want it inserted: their own wording, tidied, one to three sentences. \
            "name" is 2 to 4 lowercase words (it becomes /s some-name). "phrase" is a short piece copied exactly \
            from their messages that the snippet replaces (it's checked against what they typed). "why" is one \
            short sentence on when it helps, with no counts (Deck shows how often they typed it).

            Repeated lines:
            \(phrases.isEmpty ? "(none)" : phrases.joined(separator: "\n"))

            Recent messages:
            \(recent.joined(separator: "\n"))

            Existing snippets:
            \(have.isEmpty ? "(none)" : have.joined(separator: "\n"))
            """
    }

    /// The suggestions in Claude's answer that you typed at least twice and don't already have,
    /// most often first; nil when there's no answer (an error, or not signed in).
    static func parse(_ output: String, messages: [SnippetHistory.Message], existing: [Snippet]) -> [Suggestion]? {
        guard let items = ActivitySummarizer.structured(output)?["suggestions"] as? [[String: Any]] else { return nil }
        let names = Set(existing.map { Snippet.slug($0.name) })
        let texts = Set(existing.map { SnippetHistory.normalize($0.text) })
        var out: [Suggestion] = []
        for item in items {
            guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let phrase = item["phrase"] as? String,
                  !names.contains(Snippet.slug(name)), !texts.contains(SnippetHistory.normalize(text)),
                  !out.contains(where: { Snippet.slug($0.snippet.name) == Snippet.slug(name) }) else { continue }
            let uses = SnippetHistory.uses(of: phrase, in: messages)
            guard uses.count >= 2 else { continue }
            out.append(Suggestion(snippet: Snippet(name: String(name.prefix(40)), text: text), why: item["why"] as? String ?? "",
                                  phrase: phrase, count: uses.count, sessions: uses.sessions))
        }
        return out.sorted { $0.count > $1.count }
    }
}
