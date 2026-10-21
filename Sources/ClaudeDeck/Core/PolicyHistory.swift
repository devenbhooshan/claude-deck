import Foundation

/// The tool calls in your past sessions, to suggest rules from what Claude actually does and to
/// show what a rule would have caught.
enum PolicyHistory {
    struct Call: Equatable {
        let tool: String
        /// The command, or the file or path it touched.
        let subject: String
        let cwd: String
        let session: String
        let at: Date?
    }

    /// Commands that share their first words ("railway ssh", "gh pr merge"), with how often they ran.
    struct Family: Equatable {
        let key: String
        var count = 0
        var sessions: Set<String> = []
        /// A couple of different examples, with anything that looks like a secret masked.
        var examples: [String] = []
    }

    /// What a rule would have caught.
    struct Hits: Equatable {
        var count = 0
        var sessions: Set<String> = []
        var example: String?
    }

    private static let marker = Data(#""type":"tool_use""#.utf8)

    /// Every tool call (with a command or path) in transcripts from the last `days` days.
    static func calls(days: Int = 30, now: Date = Date()) -> [Call] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var calls: [Call] = []
        let dirs = (try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let session = file.deletingPathExtension().lastPathComponent
                // Byte-level: transcripts run to hundreds of MB, and only lines with tool calls matter.
                for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                    let at = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFractions.date(from:))
                    if let at, at < cutoff { continue }
                    for item in content where item["type"] as? String == "tool_use" {
                        guard let tool = item["name"] as? String else { continue }
                        let subject = Policies.subject(of: item["input"] as? [String: Any] ?? [:])
                        if subject.isEmpty { continue }
                        calls.append(Call(tool: tool, subject: subject, cwd: obj["cwd"] as? String ?? "", session: session, at: at))
                    }
                }
            }
        }
        return calls
    }

    /// Commands that only look at things, run constantly, and say nothing about risk.
    private static let everyday: Set<String> = [
        "cd", "echo", "printf", "export", "ls", "cat", "head", "tail", "grep", "rg", "sed", "awk", "wc", "sort", "uniq",
        "cut", "tr", "true", "false", "sleep", "test", "[", "[[", "find", "jq", "xargs", "pwd", "which", "date", "set",
        "for", "do", "done", "if", "then", "fi", "else", "while", "mkdir", "touch", "basename", "dirname", "diff", "tee",
        "python3", "python", "node", "ruby", "base64", "column", "file", "stat", "realpath", "open", "less", "env",
        "break", "continue", "case", "esac", "until", "local", "return", "exit", "function", "elif", "in", "{", "}",
    ]

    /// Heredoc bodies (`<<'EOF' … EOF`): data or a script for another program, not shell commands.
    private static let heredoc = try! NSRegularExpression(
        pattern: #"<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)"#,
        options: [.dotMatchesLineSeparators])

    /// A shell line split into its commands at ;, &&, ||, | and new lines, outside quotes, with
    /// heredoc bodies left out.
    static func commands(in line: String) -> [String] {
        let text = heredoc.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "<<$2")
        var parts: [String] = [], current = "", quote: Character?, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { current.append(ch); escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
            } else if ";|&\n".contains(ch) {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The first words of each command in a shell line, e.g. "railway ssh" for
    /// `cd x && FOO=1 railway ssh 'printenv'`; everyday commands are left out.
    static func families(of command: String) -> [(key: String, segment: String)] {
        var out: [(String, String)] = []
        for segment in commands(in: command) {
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            // Leading VAR=value assignments set up the command; they aren't it.
            while let first = words.first, first.contains("="), first.first.map({ $0.isLetter || $0 == "_" }) == true {
                words.removeFirst()
            }
            guard let program = words.first, !everyday.contains(program), program.first.map({ $0.isLetter || "./~".contains($0) }) == true,
                  program.contains(where: \.isLetter),
                  program.allSatisfy({ $0.isLetter || $0.isNumber || "./~_-".contains($0) }) else { continue }
            var key = [program]
            for w in words.dropFirst() {
                guard key.count < 3, w.first?.isLowercase == true,
                      w.allSatisfy({ $0.isLowercase || $0.isNumber || ":_-".contains($0) }) else { break }
                key.append(w)
            }
            out.append((key.joined(separator: " "), segment))
        }
        return out
    }

    /// The command families in `calls`, most frequent first.
    static func families(_ calls: [Call], limit: Int = 120) -> [Family] {
        var byKey: [String: Family] = [:]
        for call in calls where call.tool == "Bash" {
            for (key, segment) in families(of: call.subject) {
                var f = byKey[key] ?? Family(key: key)
                f.count += 1
                f.sessions.insert(call.session)
                let shown = String(redact(segment).prefix(160))
                if f.examples.count < 2 && !f.examples.contains(shown) { f.examples.append(shown) }
                byKey[key] = f
            }
        }
        return Array(byKey.values.sorted { ($0.count, $1.key) > ($1.count, $0.key) }.prefix(limit))
    }

    /// Masks what looks like a secret: API keys and tokens, credentials in URLs, webhook URLs,
    /// `password=…` values and long random strings.
    static func redact(_ text: String) -> String {
        let patterns = [
            #"(?i)\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprs]-[\w-]+"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#, #"hooks\.slack\.com/services/\S+"#, #"\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]+"#,
            #"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#, #"(?i)(?<=(?:password|passwd|secret|token|api_key|apikey|api-key)[=:])\s*[^\s'"&]+"#,
            // Long random strings (letters and digits mixed); paths and words don't qualify.
            #"\b(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{40,}\b"#,
        ]
        return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: "‹redacted›", options: .regularExpression) }
    }

    /// What `rule` would have caught in `calls`.
    static func hits(of rule: PolicyRule, in calls: [Call]) -> Hits {
        var hits = Hits()
        for call in calls where Policies.matches(rule, tool: call.tool, subject: call.subject, cwd: call.cwd) {
            hits.count += 1
            hits.sessions.insert(call.session)
            if hits.example == nil {
                // The line that matched, not just the start of a long command.
                let lines = call.subject.split(separator: "\n").map(String.init)
                let line = lines.first { Policies.matches(rule, tool: call.tool, subject: $0, cwd: call.cwd) } ?? lines.first ?? ""
                hits.example = String(redact(line.trimmingCharacters(in: .whitespaces)).prefix(160))
            }
        }
        return hits
    }
}

/// Rules Claude suggests from your history, for you to add.
enum PolicySuggestions {
    struct Suggestion: Equatable, Identifiable {
        var rule: PolicyRule
        /// Why it's worth having, citing what Claude did.
        var why: String
        var hits: PolicyHistory.Hits
        var id: String { rule.id }
    }

    static let schema = #"{"type":"object","properties":{"suggestions":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"scope":{"type":"string","enum":["commands","files","anyTool"]},"kind":{"type":"string","enum":["contains","startsWith","path","regex"]},"text":{"type":"string"},"except":{"type":"string"},"decision":{"type":"string","enum":["ask","deny"]},"message":{"type":"string"},"why":{"type":"string"}},"required":["name","scope","kind","text","except","decision","message","why"]}}},"required":["suggestions"]}"#

    static func prompt(families: [PolicyHistory.Family], days: Int, existing: [PolicyRule]) -> String {
        let list = families.map { f in
            "- \(f.key)  (\(f.count)× in \(f.sessions.count) sessions)" + f.examples.map { "\n    e.g. \($0)" }.joined()
        }.joined(separator: "\n")
        let have = existing.map { r in "- \(r.name): \(r.match.map { "\($0.kind.rawValue) \($0.text)" } ?? r.pattern)" }.joined(separator: "\n")
        return """
            You help a developer set guardrails for their coding agent (Claude Code). Below are the shell \
            commands the agent ran in their last \(days) days, grouped by first words (with counts and \
            examples), and the rules they already have.

            Suggest up to 8 NEW rules for things that are risky for this developer specifically: actions on \
            production or shared systems, anything irreversible, leaking secrets, spending money, or changing \
            other people's work. Base every suggestion on commands in the list; never invent tools they don't use. \
            Don't repeat what an existing rule already covers. Skip everyday safe work: reading, searching, \
            building, testing, local git.

            Make each rule as narrow as possible so it never fires on safe commands. Prefer kind "contains" or \
            "startsWith" with plain words (e.g. "railway variables set"); use "regex" only when needed (it is \
            searched in the whole command line; prefix (?i) to ignore case). Use "except" for a safe variant \
            (e.g. "--dry-run"), or "". Prefer decision "ask" (the developer approves each time); use "deny" only \
            for what should never happen. "message" is one short sentence saying what the action does, shown \
            when it fires. "why" is one sentence citing the evidence (e.g. "Ran 38 times with PROD_DATABASE_URL"). \
            "name" is at most 40 characters.

            Commands:
            \(list)

            Existing rules:
            \(have.isEmpty ? "(none)" : have)
            """
    }

    /// The suggestions in Claude's answer that make valid rules and would have caught something in
    /// `calls`, most often first.
    static func parse(_ output: String, calls: [PolicyHistory.Call]) -> [Suggestion] {
        guard let items = ActivitySummarizer.structured(output)?["suggestions"] as? [[String: Any]] else { return [] }
        var out: [Suggestion] = []
        for item in items {
            guard let name = item["name"] as? String, let text = item["text"] as? String,
                  let scope = (item["scope"] as? String).flatMap(PolicyScope.init(rawValue:)),
                  let kind = (item["kind"] as? String).flatMap(PolicyMatch.Kind.init(rawValue:)),
                  let decision = (item["decision"] as? String).flatMap(PolicyDecision.init(rawValue:)),
                  let rule = Policies.rule(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: String(name.prefix(60)),
                                           scope: scope, match: PolicyMatch(kind: kind, text: text, except: item["except"] as? String ?? ""),
                                           decision: decision, message: item["message"] as? String ?? "", folders: [])
            else { continue }
            let hits = PolicyHistory.hits(of: rule, in: calls)
            if hits.count > 0 { out.append(Suggestion(rule: rule, why: item["why"] as? String ?? "", hits: hits)) }
        }
        return out.sorted { $0.hits.count > $1.hits.count }
    }
}

extension ISO8601DateFormatter {
    /// Claude Code's transcript timestamps: "2026-10-21T09:23:06.466Z".
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
