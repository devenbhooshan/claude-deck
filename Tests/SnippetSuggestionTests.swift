import Foundation

private func said(_ content: Any, at: String? = "2026-10-20T10:00:00.000Z", extra: [String: Any] = [:]) -> [String: Any] {
    var line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
    if let at { line["timestamp"] = at }
    return line.merging(extra) { $1 }
}

func snippetSuggestionTests() {
    let now = ISO8601DateFormatter.withFractions.date(from: "2026-10-21T00:00:00.000Z")!

    test("snippet history: what you typed, newest first") {
        let box = Sandbox(); defer { box.cleanup() }
        box.jsonl("claude/projects/-p/s1.jsonl", [
            said("keep it short and crisp please"),
            said([["type": "text", "text": "run the tests first"], ["type": "image"]], at: "2026-10-20T11:00:00.000Z"),
            said("no timestamp here", at: nil),
            said([["type": "tool_result", "tool_use_id": "1", "content": "ok"]]),   // no text: nothing typed
            said("/compact"),
            said("<command-name>/model</command-name>"),
            said("[Claude Deck] Fleet: api finished"),
            said("Caveat: the messages below were generated"),
            said("[Request interrupted by user]"),
            said("   "),
            said(String(repeating: "x", count: 2001)),                            // a paste, not typing
            said("subagent prompt", extra: ["isSidechain": true]),
            said("hook output", extra: ["isMeta": true]),
            said("too old", at: "2026-01-01T00:00:00.000Z"),
            said(42),
            ["type": "assistant", "message": ["content": "says \"type\":\"user\""]],
        ])
        let stale = box.jsonl("claude/projects/-p/s0.jsonl", [said("ancient")])
        setMTime(stale, now.addingTimeInterval(-90 * 86400))
        box.write("claude/projects/-p/notes.txt", "ignored")
        box.write("claude/projects/stray.jsonl", "not in a folder")
        let s1 = ClaudePaths.projects.appendingPathComponent("-p/s1.jsonl")
        let h = try FileHandle(forWritingTo: s1); h.seekToEndOfFile(); h.write(Data(#"{"type":"user" broken"#.utf8)); try h.close()
        let found = SnippetHistory.messages(days: 30, now: now)
        expectEqual(found.map(\.text), ["run the tests first", "keep it short and crisp please", "no timestamp here"])
        expectEqual(found[0].session, "s1")
        try FileManager.default.removeItem(at: ClaudePaths.projects)
        expect(SnippetHistory.messages(days: 30, now: now).isEmpty, "no projects folder yet")
    }

    test("snippet history: repeated lines and sentences, counted once per message") {
        let messages = [
            SnippetHistory.Message(text: "Fix the login bug. Keep it short and crisp!\nKeep it short and crisp", session: "a", at: nil),
            SnippetHistory.Message(text: "keep it   SHORT and crisp.", session: "b", at: nil),
            SnippetHistory.Message(text: "Check today's standup on slack", session: "b", at: nil),
            SnippetHistory.Message(text: "check today's standup on slack. ok", session: "c", at: nil),
            SnippetHistory.Message(text: "ok. ok", session: "c", at: nil),                 // too short to count
            SnippetHistory.Message(text: "Fix the login bug", session: "a", at: nil),
        ]
        let phrases = SnippetHistory.repeated(messages)
        expectEqual(phrases.map(\.count), [2, 2, 2])
        expectEqual(Set(phrases.map { SnippetHistory.normalize($0.text) }),
                    ["keep it short and crisp", "check today's standup on slack", "fix the login bug"])
        expectEqual(phrases.first { $0.text.hasPrefix("Keep") }?.sessions, ["a", "b"])
        expectEqual(SnippetHistory.normalize("  Keep it\tSHORT. "), "keep it short")
        expect(SnippetHistory.uses(of: "short and crisp", in: messages) == (2, 2))
        expect(SnippetHistory.uses(of: "ok", in: messages) == (0, 0), "too short to check")
    }

    test("snippet suggestions: prompt, and only what you really typed") {
        let messages = [
            SnippetHistory.Message(text: "keep it short and crisp\nline two", session: "a", at: nil),
            SnippetHistory.Message(text: "Keep it short and crisp.", session: "b", at: nil),
            SnippetHistory.Message(text: "no em dashes", session: "b", at: nil),
            SnippetHistory.Message(text: "no em dashes", session: "c", at: nil),
        ]
        let mine = Snippet(name: "No dashes", text: "No em dashes.")
        let prompt = SnippetSuggestions.prompt(messages: messages, days: 30, existing: [mine])
        expect(prompt.contains("\"keep it short and crisp\"  (2× in 2 sessions)"))
        expect(prompt.contains("- keep it short and crisp ⏎ line two"))
        expect(prompt.contains("- No dashes: No em dashes."))
        let empty = SnippetSuggestions.prompt(messages: [], days: 30, existing: [])
        expect(empty.contains("Repeated lines:\n(none)") && empty.contains("Existing snippets:\n(none)"))

        func answer(_ items: [[String: Any]]) -> String {
            let inner = String(data: try! JSONSerialization.data(withJSONObject: ["suggestions": items]), encoding: .utf8)!
            return String(data: try! JSONSerialization.data(withJSONObject: ["result": inner]), encoding: .utf8)!
        }
        let out = answer([
            ["name": "Short and crisp", "text": "Keep replies short and crisp.", "phrase": "short and crisp", "why": "2 messages"],
            ["name": "short and crisp", "text": "Again", "phrase": "short and crisp", "why": ""],           // same name twice
            ["name": "dashes", "text": "no em dashes", "phrase": "no em dashes", "why": ""],               // you have it
            ["name": "no dashes", "text": "Different", "phrase": "no em dashes", "why": ""],              // name taken
            ["name": "made up", "text": "Use tabs.", "phrase": "always use tabs", "why": ""],              // never typed
            ["name": "line two", "text": "Line two.", "phrase": "line two", "why": ""],                   // typed once
            ["name": " ", "text": "x", "phrase": "x"],
            ["name": "no text", "text": "", "phrase": "short and crisp"],
            ["name": "no phrase", "text": "y"],
        ])
        let found = SnippetSuggestions.parse(out, messages: messages, existing: [mine]) ?? []
        expectEqual(found.map(\.snippet.name), ["Short and crisp"])
        expectEqual(found[0].snippet.text, "Keep replies short and crisp.")
        expectEqual(found[0].snippet.scope, .global)
        expect(found[0].count == 2 && found[0].sessions == 2 && found[0].why == "2 messages" && found[0].phrase == "short and crisp")
        expectEqual(found[0].id, found[0].snippet.id)
        let both = SnippetSuggestions.parse(answer([
            ["name": "once", "text": "a", "phrase": "no em dashes"],
            ["name": "twice", "text": "b", "phrase": "keep it short"],
        ]), messages: messages + [SnippetHistory.Message(text: "keep it short", session: "d", at: nil)], existing: []) ?? []
        expectEqual(both.map(\.snippet.name), ["twice", "once"])
        expect(SnippetSuggestions.parse("garbage", messages: messages, existing: []) == nil)
        expect(SnippetSuggestions.parse(#"{"is_error":true,"result":"Not logged in"}"#, messages: messages, existing: []) == nil)
        expect((try? JSONSerialization.jsonObject(with: Data(SnippetSuggestions.schema.utf8))) != nil)
    }
}
