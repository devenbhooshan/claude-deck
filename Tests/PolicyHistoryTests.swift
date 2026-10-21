import Foundation

private func toolLine(_ tool: String, _ input: [String: Any], cwd: String = "/p", at: String? = "2026-10-20T10:00:00.000Z") -> [String: Any] {
    var line: [String: Any] = ["type": "assistant", "cwd": cwd,
                               "message": ["content": [["type": "text", "text": "x"], ["type": "tool_use", "name": tool, "input": input]]]]
    if let at { line["timestamp"] = at }
    return line
}

func policyHistoryTests() {
    test("reads tool calls from recent transcripts") {
        let box = Sandbox(); defer { box.cleanup() }
        let now = ISO8601DateFormatter.withFractions.date(from: "2026-10-21T00:00:00.000Z")!
        box.jsonl("claude/projects/-p/s1.jsonl", [
            toolLine("Bash", ["command": "railway ssh 'printenv'"]),
            toolLine("Read", ["file_path": "/p/.env"], at: nil),
            toolLine("Grep", ["pattern": "x"]),                       // nothing to match on
            toolLine("Bash", ["command": "old"], at: "2026-01-01T00:00:00.000Z"),
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "1"]]]],
            ["type": "assistant", "message": ["content": "plain"], "note": #""type":"tool_use""#],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "input": [:]]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read"]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "no cwd"]]]]],
        ])
        let note = box.write("claude/projects/-p/notes.txt", "ignored")
        let stale = box.jsonl("claude/projects/-p/s0.jsonl", [toolLine("Bash", ["command": "ancient"])])
        setMTime(stale, now.addingTimeInterval(-90 * 86400))
        setMTime(note, now)
        box.write("claude/projects/stray.jsonl", "not in a folder")
        let s1 = ClaudePaths.projects.appendingPathComponent("-p/s1.jsonl")
        let h = try FileHandle(forWritingTo: s1); h.seekToEndOfFile(); h.write(Data(#"{"type":"tool_use" broken"#.utf8)); try h.close()
        let calls = PolicyHistory.calls(days: 30, now: now)
        expectEqual(calls.map(\.subject), ["railway ssh 'printenv'", "/p/.env", "no cwd"])
        expectEqual(calls[2].cwd, "")
        expectEqual(calls[0].session, "s1")
        expectEqual(calls[0].cwd, "/p")
        expect(calls[0].at != nil && calls[1].at == nil)
        try FileManager.default.removeItem(at: ClaudePaths.projects)
        expect(PolicyHistory.calls(days: 30, now: now).isEmpty, "no projects folder yet")
    }
    test("command families: first words, quote-aware, heredocs and everyday commands left out") {
        let line = """
            cd /x && FOO=1 BAR=2 railway ssh 'printenv | grep A; echo b' | head -3; gh pr merge 12 --merge
            cat > f <<'EOF'
            return 1
            import os
            EOF
            bin/kamal app exec --reuse "bin/rails runner 'x'" && ./build.sh --install || -f x; --opt=1 tool; gh run viewAll
            echo "a \\" ; b" ; for i in 1; do break; done
            """
        expectEqual(PolicyHistory.families(of: line).map(\.key), ["railway ssh", "gh pr merge", "bin/kamal app exec", "./build.sh", "gh run"])
        expectEqual(PolicyHistory.commands(in: #"a 'b;c' && d "e|f" \; g"#), ["a 'b;c'", #"d "e|f" \; g"#]) // \; isn't a separator
        let calls = [
            PolicyHistory.Call(tool: "Bash", subject: "railway ssh 'a' && railway ssh 'b'", cwd: "", session: "s1", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "railway ssh 'a'", cwd: "", session: "s2", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "railway ssh 'c'", cwd: "", session: "s2", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "gh pr merge 1", cwd: "", session: "s1", at: nil),
            PolicyHistory.Call(tool: "Read", subject: "/p/x", cwd: "", session: "s1", at: nil),
        ]
        let fams = PolicyHistory.families(calls)
        expectEqual(fams.map(\.key), ["railway ssh", "gh pr merge"])
        expectEqual(fams[0].count, 4)
        expectEqual(fams[0].sessions, ["s1", "s2"])
        expectEqual(fams[0].examples, ["railway ssh 'a'", "railway ssh 'b'"])
        expectEqual(PolicyHistory.families(calls, limit: 1).count, 1)
    }
    test("secrets are masked") {
        let r = PolicyHistory.redact
        expectEqual(r("export OPENAI=sk-proj-abcdefghijklmnop1234"), "export OPENAI=‹redacted›")
        expectEqual(r("curl https://hooks.slack.com/services/T0/B0/xyz -d x"), "curl https://‹redacted› -d x")
        expectEqual(r("psql postgres://user:hunter2@db:5432/x"), "psql postgres://‹redacted›@db:5432/x")
        expectEqual(r("PASSWORD=hunter2 make"), "PASSWORD=‹redacted› make")
        expectEqual(r("gh auth ghp_abcdefghijklmnopqrstuvwxyz0123"), "gh auth ‹redacted›")
        expectEqual(r("key AKIAABCDEFGHIJKLMNOP"), "key ‹redacted›")
        expectEqual(r("t xoxb-123-abc"), "t ‹redacted›")
        expectEqual(r("jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.sig"), "jwt ‹redacted›")
        expectEqual(r("id 9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a"), "id ‹redacted›")
        let path = "/private/tmp/claude-501/-Users-devenbhooshan-worksplace-ai-workspace-claude-deck/x"
        expectEqual(r(path), path)
    }
    test("what a rule would have caught") {
        let rule = Policies.rule(id: "r", name: "Merges", scope: .commands, match: PolicyMatch(kind: .contains, text: "gh pr merge"),
                                 decision: .ask, message: "", folders: [])!
        let calls = [
            PolicyHistory.Call(tool: "Bash", subject: "cd x\n  gh pr merge 1 --merge", cwd: "", session: "s1", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "gh pr merge 2", cwd: "", session: "s2", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "gh pr view 2", cwd: "", session: "s2", at: nil),
        ]
        let hits = PolicyHistory.hits(of: rule, in: calls)
        expectEqual(hits.count, 2)
        expectEqual(hits.sessions, ["s1", "s2"])
        expectEqual(hits.example, "gh pr merge 1 --merge") // the line that matched
        // A rule that only matches across lines still gets an example.
        let multi = Policies.rule(id: "m", name: "M", scope: .commands, match: PolicyMatch(kind: .regex, text: #"a\nb"#),
                                  decision: .ask, message: "", folders: [])!
        expectEqual(PolicyHistory.hits(of: multi, in: [PolicyHistory.Call(tool: "Bash", subject: "a\nb", cwd: "", session: "s", at: nil)]).example, "a")
        expectEqual(PolicyHistory.hits(of: multi, in: []).count, 0)
        let empty = Policies.rule(id: "e", name: "E", scope: .anyTool, match: PolicyMatch(kind: .regex, text: "^$"),
                                  decision: .ask, message: "", folders: [])!
        expectEqual(PolicyHistory.hits(of: empty, in: [PolicyHistory.Call(tool: "X", subject: "", cwd: "", session: "s", at: nil)]).example, "")
    }
    test("suggestions: the prompt, and parsing Claude's answer") {
        let fams = [PolicyHistory.Family(key: "railway ssh", count: 3, sessions: ["a"], examples: ["railway ssh 'x'"])]
        let mine = Policies.rule(id: "c", name: "No publish", scope: .commands, match: PolicyMatch(kind: .contains, text: "npm publish"),
                                 decision: .deny, message: "", folders: [])!
        let prompt = PolicySuggestions.prompt(families: fams, days: 30, existing: [mine, Policies.builtins[0]])
        expect(prompt.contains("railway ssh  (3× in 1 sessions)\n    e.g. railway ssh 'x'"))
        expect(prompt.contains("- No publish: contains npm publish"))
        expect(prompt.contains("- Running code against production: \\b(?:kamal"))
        expect(PolicySuggestions.prompt(families: fams, days: 30, existing: []).contains("(none)"))
        let calls = [
            PolicyHistory.Call(tool: "Bash", subject: "railway variables --set A=1", cwd: "", session: "s", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "railway variables --set B=1", cwd: "", session: "s", at: nil),
            PolicyHistory.Call(tool: "Bash", subject: "gh pr merge 3 --admin", cwd: "", session: "s", at: nil),
        ]
        let answer: [String: Any] = ["structured_output": ["suggestions": [
            ["name": "Admin merges", "scope": "commands", "kind": "contains", "text": "--admin", "except": "", "decision": "deny",
             "message": "Skips checks.", "why": "Ran gh pr merge --admin."],
            ["name": "Railway variables", "scope": "commands", "kind": "startsWith", "text": "railway variables --set",
             "decision": "ask"],
            ["name": "Never ran", "scope": "commands", "kind": "contains", "text": "terraform apply", "except": "",
             "decision": "ask", "message": "", "why": ""],
            ["name": "Broken", "scope": "commands", "kind": "regex", "text": "([", "except": "", "decision": "ask", "message": "", "why": ""],
            ["name": "Bad scope", "scope": "planets", "kind": "contains", "text": "x", "except": "", "decision": "ask", "message": "", "why": ""],
            ["scope": "commands"],
        ]]]
        let out = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
        let found = PolicySuggestions.parse(out, calls: calls)
        expectEqual(found.map(\.rule.name), ["Railway variables", "Admin merges"]) // most caught first; no-shows dropped
        expectEqual(found[0].hits.count, 2)
        expectEqual(found[0].rule.message, "")
        expectEqual(found[0].why, "")
        expectEqual(found[1].rule.decision, .deny)
        expectEqual(found[1].why, "Ran gh pr merge --admin.")
        expect(found[0].id.hasPrefix("custom-"))
        expect(PolicySuggestions.parse("garbage", calls: calls).isEmpty)
        expect((try? JSONSerialization.jsonObject(with: Data(PolicySuggestions.schema.utf8))) != nil)
    }
}
