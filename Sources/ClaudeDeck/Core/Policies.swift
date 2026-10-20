import Foundation

/// Guardrails for every Claude Code session on this Mac, managed in one place by Deck.
///
/// A `PreToolUse` hook runs the small `deck-policy` checker (bundled in Deck.app) before each tool
/// call. It reads the policy file, and when a rule matches it denies the call (Claude is told why),
/// asks you, or allows it, and logs the decision for Deck to show. Deck needn't be running.
///
/// This file is compiled into that checker too, so it uses Foundation only.
enum PolicyDecision: String, Codable, CaseIterable {
    case deny, ask, allow

    /// Deny beats ask beats allow when several rules match.
    var strength: Int {
        switch self {
        case .deny: 2
        case .ask: 1
        case .allow: 0
        }
    }
}

struct PolicyRule: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Tool names it applies to (Bash, Read, Edit…); empty means every tool.
    var tools: [String]
    /// A regular expression searched in the call's command or file path. `(?i)` ignores case.
    var pattern: String
    /// A regular expression that, if it also matches, lets the call through after all.
    var except: String?
    var decision: PolicyDecision
    /// Why: told to Claude on a deny, shown to you on an ask.
    var message: String
    /// How the rule was described in Deck's editor (your own rules); `pattern` is built from it.
    var match: PolicyMatch?
    /// Folders it applies in (and their subfolders); nil or empty means everywhere.
    var folders: [String]?
}

/// What a rule looks at: shell commands, the files Claude reads and edits, or any tool call.
enum PolicyScope: String, Codable, CaseIterable {
    case commands, files, anyTool

    static let fileTools = ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit"]

    var tools: [String] {
        switch self {
        case .commands: ["Bash"]
        case .files: Self.fileTools
        case .anyTool: []
        }
    }

    init(tools: [String]) {
        self = tools == ["Bash"] ? .commands : tools == Self.fileTools ? .files : .anyTool
    }
}

/// A rule as written in the editor, without regular expressions unless you choose them.
struct PolicyMatch: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// The words appear in this order (any spacing, any case): "npm publish".
        case contains
        /// A command starts with the words, also after `;`, `&&` or `|`: "git reset --hard".
        case startsWith
        /// A file path or name, with * and ** wildcards: "*.pem", "secrets/**".
        case path
        /// A regular expression, as is.
        case regex
    }

    var kind: Kind
    var text: String
    /// Text that, if also present, lets the call through (same kind; empty for none).
    var except: String = ""

    /// The regular expression for `text` as `kind`; nil if it's empty or doesn't compile.
    static func pattern(_ kind: Kind, _ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let joined = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"\s+"#)
        let start = words.first!.first!.isWordChar ? #"\b"# : ""
        let end = words.last!.last!.isWordChar ? #"\b"# : ""
        let pattern: String
        switch kind {
        case .contains: pattern = "(?i)" + start + joined + end
        case .startsWith: pattern = #"(?i)(?:^|[;&|(]|\$\()\s*"# + joined + end
        case .path:
            let glob = NSRegularExpression.escapedPattern(for: text.trimmingCharacters(in: .whitespaces))
                .replacingOccurrences(of: #"\*\*"#, with: ".*")
                .replacingOccurrences(of: #"\*"#, with: "[^/]*")
                .replacingOccurrences(of: #"\?"#, with: "[^/]")
            pattern = #"(?:^|/)"# + glob + "$"
        case .regex: pattern = text
        }
        return Policies.isValid(pattern) ? pattern : nil
    }
}

private extension Character {
    var isWordChar: Bool { isLetter || isNumber || self == "_" }
}

/// What you've changed: built-in rules switched on or off, and your own rules.
struct PolicySettings: Codable, Equatable {
    var overrides: [String: Bool] = [:]
    var rules: [PolicyRule] = []

    init(overrides: [String: Bool] = [:], rules: [PolicyRule] = []) {
        self.overrides = overrides
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try c.decodeIfPresent([String: Bool].self, forKey: .overrides) ?? [:]
        rules = try c.decodeIfPresent([PolicyRule].self, forKey: .rules) ?? []
    }
}

/// One decision the checker made, as logged.
struct PolicyEvent: Codable, Equatable {
    var at: Date
    var session: String
    var cwd: String
    var tool: String
    var rule: String
    var decision: PolicyDecision
    var subject: String
}

enum Policies {
    /// Where the policy file and the log live. Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck")
    static var fileURL: URL { dir.appendingPathComponent("policies.json") }
    static var logURL: URL { dir.appendingPathComponent("policy-log.jsonl") }
    /// The checker's file name inside Deck.app, also how its hook entry is recognised.
    static let checkerName = "deck-policy"
    /// The log is started afresh once it passes this size.
    nonisolated(unsafe) static var logLimit = 2_000_000

    private static let envFile = #"(?:^|[\s<>'"=/])\.env(?:\.[\w-]+)?(?=$|[\s'";|&)>])"#
    private static let envExample = #"\.env\.(?:example|sample|template|dist)\b"#

    /// Always on, and can't be switched off: Claude may not edit the rules or the log.
    static let guardRule = PolicyRule(
        id: "protect-policies", name: "Protect Deck's policies", tools: [],
        pattern: #"ClaudeDeck/(?:policies\.json|policy-log\.jsonl)"#, except: nil, decision: .deny,
        message: "Deck's policy file and log can only be changed from Claude Deck.")

    static let builtins: [PolicyRule] = [
        PolicyRule(id: "block-rm-rf-home", name: "Deleting / or your home folder", tools: ["Bash"],
                   pattern: #"\brm\s+(?:-\S+\s+)+(?:/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\.\.?/?)(?=$|[\s;&|)])"#,
                   except: nil, decision: .deny,
                   message: "Recursive deletes of /, ~, . or .. are blocked. Delete specific paths instead."),
        PolicyRule(id: "ask-rm-rf", name: "Recursive force delete (rm -rf)", tools: ["Bash"],
                   pattern: #"\brm\s+(?:-\S+\s+)*-(?:[a-zA-Z]*[rR][a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*[rR])[a-zA-Z]*\b"#,
                   except: nil, decision: .ask, message: "rm -rf deletes without a way back."),
        PolicyRule(id: "block-sudo", name: "sudo", tools: ["Bash"], pattern: #"(?:(?:^|[;&|(`]|\$\()\s*|\b(?:then|do|xargs|exec|env|time|nohup)\s+)sudo\s"#,
                   except: nil, decision: .deny,
                   message: "sudo is blocked. Ask the user to run commands that need admin rights."),
        PolicyRule(id: "block-force-push", name: "git push --force", tools: ["Bash"],
                   pattern: #"\bgit\b[^;&|\n]*\bpush\b[^;&|\n]*(?:\s--force\S*|\s-[a-zA-Z]*f\b|\s\+\S+)"#,
                   except: nil, decision: .deny,
                   message: "Force pushes rewrite shared history and are blocked. Push normally or ask the user."),
        PolicyRule(id: "ask-push-main", name: "Pushing to main or master", tools: ["Bash"],
                   pattern: #"\bgit\b[^;&|\n]*\bpush\b[^;&|\n]*\s(?:\S+:)?(?:main|master)\b"#,
                   except: nil, decision: .ask, message: "This pushes straight to main."),
        PolicyRule(id: "block-env-files", name: "Secret .env files", tools: [],
                   pattern: envFile, except: envExample, decision: .deny,
                   message: ".env files hold secrets and are off limits. Ask the user for the values you need."),
        PolicyRule(id: "ask-destructive-sql", name: "DROP, TRUNCATE or DELETE without WHERE", tools: ["Bash"],
                   pattern: #"(?i)\b(?:drop\s+(?:table|database|schema)|truncate\s+(?:table\s+)?\w+)\b|\bdelete\s+from\s+[\w."`]+\s*(?:;|$|["'])"#,
                   except: nil, decision: .ask, message: "This SQL deletes data."),
        PolicyRule(id: "ask-terraform", name: "terraform apply / destroy", tools: ["Bash"],
                   pattern: #"\bterraform\b[^;&|\n]*\s(?:apply|destroy|import|state\s+(?:rm|mv|push))\b"#,
                   except: nil, decision: .ask, message: "This changes live infrastructure."),
        PolicyRule(id: "ask-kubectl", name: "kubectl changes", tools: ["Bash"],
                   pattern: #"\bkubectl\b[^;&|\n]*\s(?:apply|create|delete|replace|patch|edit|scale|rollout|drain|cordon|set)\b"#,
                   except: nil, decision: .ask, message: "This changes a live cluster."),
        PolicyRule(id: "block-curl-pipe-shell", name: "Piping a download into a shell", tools: ["Bash"],
                   pattern: #"\b(?:curl|wget)\b[^;&\n]*\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b"#,
                   except: nil, decision: .deny,
                   message: "Running a downloaded script unseen is blocked. Download it, show it to the user, then run it."),
    ]

    /// Built-ins that start switched off (they'd interrupt too often for most people).
    static let offByDefault: Set<String> = ["ask-push-main"]

    static func isOn(_ rule: PolicyRule, in settings: PolicySettings) -> Bool {
        settings.overrides[rule.id] ?? !offByDefault.contains(rule.id)
    }

    /// The rules in force: the guard, the built-ins that are on, and your own rules that are on.
    static func active(_ settings: PolicySettings) -> [PolicyRule] {
        [guardRule] + (builtins + settings.rules).filter { isOn($0, in: settings) }
    }

    /// What a rule is matched against: the command, or else the file or path the tool touches.
    static func subject(of input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "path", "url"] {
            if let v = input[key] as? String { return v }
        }
        return ""
    }

    static func matches(_ rule: PolicyRule, tool: String, subject: String, cwd: String = "") -> Bool {
        guard rule.tools.isEmpty || rule.tools.contains(tool), applies(rule, in: cwd),
              found(rule.pattern, in: subject) else { return false }
        return !(rule.except.map { found($0, in: subject) } ?? false)
    }

    /// Whether `cwd` is one of the rule's folders or inside one (always, if it has none).
    static func applies(_ rule: PolicyRule, in cwd: String) -> Bool {
        guard let folders = rule.folders, !folders.isEmpty else { return true }
        return folders.contains { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Your own rule from the editor's fields; nil while the match is empty or invalid.
    static func rule(id: String, name: String, scope: PolicyScope, match: PolicyMatch, decision: PolicyDecision,
                     message: String, folders: [String]) -> PolicyRule? {
        guard let pattern = PolicyMatch.pattern(match.kind, match.text) else { return nil }
        let except = match.except.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : PolicyMatch.pattern(match.kind == .startsWith ? .contains : match.kind, match.except)
        let title = name.trimmingCharacters(in: .whitespaces)
        return PolicyRule(id: id, name: title.isEmpty ? match.text : title, tools: scope.tools, pattern: pattern,
                          except: except, decision: decision, message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                          match: match, folders: folders.isEmpty ? nil : folders)
    }

    /// A pattern that doesn't compile matches nothing.
    private static func found(_ pattern: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isValid(_ pattern: String) -> Bool { (try? NSRegularExpression(pattern: pattern)) != nil }

    /// The strongest matching rule (the first of equals), if any.
    static func evaluate(tool: String, input: [String: Any], cwd: String = "", settings: PolicySettings) -> PolicyRule? {
        let text = subject(of: input)
        var best: PolicyRule?
        for rule in active(settings) where matches(rule, tool: tool, subject: text, cwd: cwd) {
            if best.map({ rule.decision.strength > $0.decision.strength }) ?? true { best = rule }
        }
        return best
    }

    /// Claude Code's answer for a matching rule.
    static func hookOutput(for rule: PolicyRule) -> Data {
        let out: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": rule.decision.rawValue,
            "permissionDecisionReason": "Claude Deck policy “\(rule.name)”: \(rule.message)",
        ]]
        return try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// The checker: given the hook's stdin, what to print (nil: nothing, so Claude goes on as usual).
    static func check(_ stdin: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              (obj["hook_event_name"] as? String ?? "PreToolUse") == "PreToolUse",
              let tool = obj["tool_name"] as? String else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? ""
        guard let rule = evaluate(tool: tool, input: input, cwd: cwd, settings: load()) else { return nil }
        log(PolicyEvent(at: Date(), session: obj["session_id"] as? String ?? "", cwd: cwd,
                        tool: tool, rule: rule.id, decision: rule.decision, subject: String(subject(of: input).prefix(500))))
        return hookOutput(for: rule)
    }

    // MARK: Files

    /// Your settings; the defaults if there's no file or it can't be read.
    static func load() -> PolicySettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(PolicySettings.self, from: data) else { return PolicySettings() }
        return s
    }

    static func save(_ settings: PolicySettings) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(settings).write(to: fileURL, options: .atomic)
    }

    static func log(_ event: PolicyEvent) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > logLimit {
            try? fm.removeItem(at: logURL)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try! enc.encode(event)
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    /// The newest `limit` decisions, newest first.
    static func recent(limit: Int = 50) -> [PolicyEvent] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").reversed().lazy
            .compactMap { try? dec.decode(PolicyEvent.self, from: Data($0.utf8)) }
            .prefix(limit).map { $0 }
    }
}
