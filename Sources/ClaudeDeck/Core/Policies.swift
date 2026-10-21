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

    private static let notHelp = #"(?:^|\s)(?:--help|-h)(?:\s|$)"#

    static let builtins: [PolicyRule] = [
        // Production and deploys
        PolicyRule(id: "ask-prod-console", name: "Running code against production", tools: ["Bash"],
                   pattern: #"\b(?:kamal\s+(?:app\s+exec|console|shell|dbc)|railway\s+(?:ssh|run|connect|shell)|heroku\s+(?:run|pg:psql)|fly(?:ctl)?\s+(?:ssh|console))\b|RAILS_ENV=production|PROD_DATABASE_URL|\.env\.production\b"#,
                   except: notHelp, decision: .ask,
                   message: "This runs code on a production server or against production data."),
        PolicyRule(id: "ask-deploy", name: "Deploys and pipeline runs", tools: ["Bash"],
                   pattern: #"\b(?:kamal\s+(?:deploy|setup|redeploy|rollback|remove|app\s+(?:boot|start|stop|remove)|accessory\s+(?:boot|reboot|remove|restart|stop))|railway\s+(?:up|redeploy|down|delete|restart)|(?:fly|flyctl)\s+deploy|gh\s+(?:workflow\s+run|run\s+rerun))\b|\b(?:vercel|netlify\s+deploy)\b[^\n;&|]*--prod\b"#,
                   except: notHelp, decision: .ask, message: "This deploys, or starts a pipeline that may deploy."),
        PolicyRule(id: "ask-prod-config", name: "Changing secrets or environment variables", tools: ["Bash"],
                   pattern: #"\b(?:railway\s+variables?\b[^\n;&|]*(?:--set\b|\sset\b|\sdelete\b)|gh\s+(?:secret|variable)\s+(?:set|delete|remove)|kamal\s+(?:env\s+push|secrets\s+(?:set|push))|heroku\s+config:(?:set|unset)|fly(?:ctl)?\s+secrets\s+(?:set|unset))\b"#,
                   except: notHelp, decision: .ask, message: "This changes a deployed app's secrets or settings."),
        PolicyRule(id: "ask-cloud-changes", name: "AWS changes", tools: ["Bash"],
                   pattern: #"\baws\s+(?:--?\S+\s+(?:[^-\s]\S*\s+)?)*(?:[a-z0-9-]+)\s+(?:create|delete|put|update|modify|authorize|revoke|terminate|run|start|stop|reboot|attach|detach|associate|disassociate|remove|add|register|deregister|tag|untag|reset|restore|replace|set|enable|disable|import|copy|cancel)-[a-z0-9-]+|\baws\s+s3\s+(?:rm|rb|mv)\b|\baws\s+s3\s+sync\b[^\n;&|]*--delete\b"#,
                   except: notHelp, decision: .ask,
                   message: "This changes AWS resources (read-only describe, list and get calls aren't asked)."),
        PolicyRule(id: "ask-env-dump", name: "Printing secrets from the environment", tools: ["Bash"],
                   pattern: #"\bprintenv\b|(?:^|[;&|(]|['"])\s*(?:env|export\s+-p)\s*(?=$|[|;&)'"])|\brailway\s+variables?\b(?![^\n;&|]*(?:--set\b|\sset\b|\sdelete\b))|\bkamal\s+secrets\s+print\b|\bheroku\s+config\b(?!:)|/proc/\S+/environ"#,
                   except: notHelp, decision: .ask, message: "The output may contain API keys and passwords."),
        // Git and GitHub
        PolicyRule(id: "block-force-push-main", name: "Force pushing main or master", tools: ["Bash"],
                   pattern: #"\bgit\b(?=[^;&|\n]*\bpush\b)(?=[^;&|\n]*(?:\s--force\S*|\s-[a-zA-Z]*f\b|\s\+\S))(?=[^;&|\n]*\s\+?(?:\S+:)?(?:main|master)\b)"#,
                   except: nil, decision: .deny,
                   message: "Force pushing main rewrites shared history and is blocked. Ask the user."),
        PolicyRule(id: "ask-force-push", name: "git push --force", tools: ["Bash"],
                   pattern: #"\bgit\b[^;&|\n]*\bpush\b[^;&|\n]*(?:\s--force\S*|\s-[a-zA-Z]*f\b|\s\+\S+)"#,
                   except: nil, decision: .ask, message: "A force push overwrites the remote branch."),
        PolicyRule(id: "ask-push-main", name: "Pushing to main or master", tools: ["Bash"],
                   pattern: #"\bgit\b[^;&|\n]*\bpush\b[^;&|\n]*\s(?:\S+:)?(?:main|master)\b"#,
                   except: nil, decision: .ask, message: "This pushes straight to main."),
        PolicyRule(id: "ask-discard-changes", name: "Discarding uncommitted work", tools: ["Bash"],
                   pattern: #"\bgit\s+(?:reset\s+[^\n;&|]*--hard\b|checkout\s+(?:-f\s+|--force\s+)?(?:--\s+)?\.(?=$|[\s;&|])|restore\s+(?!(?:--staged|-S)\s+\.)(?:--?\S+\s+)*\.(?=$|[\s;&|])|clean\s+-[a-zA-Z]*[fdx]|stash\s+(?:drop|clear)\b|branch\s+(?:-D|-d\s+-f|--delete\s+--force)\b)"#,
                   except: nil, decision: .ask, message: "This throws away changes or a branch that may not be saved anywhere else."),
        PolicyRule(id: "ask-no-verify", name: "Skipping git hooks (--no-verify)", tools: ["Bash"],
                   pattern: #"\bgit\s+(?:commit|push|merge|rebase)\b[^\n;&|]*\s--no-verify\b"#,
                   except: nil, decision: .ask, message: "This skips the repo's checks (lint, tests) that run on commit or push."),
        PolicyRule(id: "ask-pr-merge", name: "Merging pull requests", tools: ["Bash"],
                   pattern: #"\bgh\s+pr\s+merge\b"#, except: notHelp, decision: .ask,
                   message: "Merging can ship straight to production."),
        PolicyRule(id: "ask-github-changes", name: "Deleting or publishing on GitHub", tools: ["Bash"],
                   pattern: #"\bgh\s+(?:repo\s+(?:delete|archive|rename|edit\b[^\n;&|]*--visibility)|release\s+(?:create|delete|edit|upload)|pr\s+close|issue\s+delete|api\b[^\n;&|]*(?:-X|--method)\s*(?:DELETE|PUT|PATCH))\b"#,
                   except: notHelp, decision: .ask, message: "This deletes, publishes or changes something on GitHub."),
        // Data
        PolicyRule(id: "ask-destructive-data", name: "Deleting or overwriting data", tools: ["Bash"],
                   pattern: #"(?i)\b(?:drop\s+(?:table|database|schema)|truncate\s+(?:table\s+)?\w+)\b|\bdelete\s+from\s+[\w."`]+\s*(?:;|$|["'])|\bupdate\s+[\w."`]+\s+set\b(?![^;'"]*\bwhere\b)|\b(?:rails|rake)\s+db:(?:drop|reset|purge|schema:load|structure:load|truncate_all|seed:replant)\b|\bflush(?:all|db)\b|\.(?:destroy_all|delete_all|update_all)\b"#,
                   except: nil, decision: .ask, message: "This deletes or rewrites rows in bulk."),
        // Secrets and files
        PolicyRule(id: "block-private-keys", name: "Private keys and credential files", tools: [],
                   pattern: #"(?:^|[\s/'"=~])(?:id_(?:rsa|ed25519|ecdsa|dsa)(?!\.pub)\b|\.aws/credentials\b|master\.key\b|\.netrc\b|\.pgpass\b)"#,
                   except: nil, decision: .deny,
                   message: "Private keys and credential files are off limits. Ask the user if you need access."),
        PolicyRule(id: "ask-env-files", name: "Secret .env files", tools: [],
                   pattern: envFile, except: envExample, decision: .ask,
                   message: ".env files hold secrets: API keys, passwords and production URLs."),
        PolicyRule(id: "ask-claude-settings", name: "Editing Claude Code's settings", tools: ["Edit", "MultiEdit", "Write"],
                   pattern: #"\.claude/settings(?:\.local)?\.json$"#, except: nil, decision: .ask,
                   message: "This changes Claude Code's permissions or hooks."),
        PolicyRule(id: "ask-package-publish", name: "Publishing packages or images", tools: ["Bash"],
                   pattern: #"\b(?:(?:npm|pnpm|yarn)\s+publish|gem\s+push|cargo\s+publish|pod\s+trunk\s+push|twine\s+upload|docker\s+push)\b"#,
                   except: #"--dry-run"#, decision: .ask, message: "This publishes to a public registry."),
        // Your Mac
        PolicyRule(id: "block-rm-rf-home", name: "Deleting / or your home folder", tools: ["Bash"],
                   pattern: #"\brm\s+(?:-\S+\s+)+(?:/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\.\.?/?)(?=$|[\s;&|)])"#,
                   except: nil, decision: .deny,
                   message: "Recursive deletes of /, ~, . or .. are blocked. Delete specific paths instead."),
        PolicyRule(id: "ask-rm-rf", name: "rm -rf outside temp folders", tools: ["Bash"],
                   pattern: #"\brm\s+(?:-\S+\s+)*-(?:[a-zA-Z]*[rR][a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*[rR])[a-zA-Z]*\b"#,
                   except: #"/tmp/|/private/tmp/|\$TMPDIR|scratchpad|\$S\b|node_modules|\.build\b|\bbuild\b|\bdist\b|DerivedData"#,
                   decision: .ask, message: "rm -rf deletes without a way back."),
        PolicyRule(id: "block-sudo", name: "sudo", tools: ["Bash"],
                   pattern: #"(?:(?:^|[;&|(`]|\$\()\s*|\b(?:then|do|xargs|exec|env|time|nohup)\s+)sudo\s"#,
                   except: nil, decision: .deny,
                   message: "sudo is blocked. Ask the user to run commands that need admin rights."),
        PolicyRule(id: "block-curl-pipe-shell", name: "Piping a download into a shell", tools: ["Bash"],
                   pattern: #"\b(?:curl|wget)\b[^;&\n]*\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b"#,
                   except: nil, decision: .deny,
                   message: "Running a downloaded script unseen is blocked. Download it, show it to the user, then run it."),
        PolicyRule(id: "ask-system-changes", name: "Changing macOS system settings", tools: ["Bash"],
                   pattern: #"\b(?:launchctl\s+(?:load|unload|bootstrap|bootout|remove|enable|disable)|crontab\s+(?!-l\b)\S|chsh\b|scutil\s+--set|networksetup\s+-set|pmset\s|csrutil\s|spctl\s+--master|dscl\s|systemsetup\s)|\bch(?:mod|own)\s+-R\s+\S+\s+(?:/|~/?|\$HOME/?)(?=$|\s)"#,
                   except: nil, decision: .ask, message: "This changes how your Mac runs, outside any project."),
        PolicyRule(id: "ask-global-install", name: "Installing tools globally", tools: ["Bash"],
                   pattern: #"\b(?:(?:npm|pnpm)\s+(?:i|install|add)\b[^\n;&|]*\s(?:-g|--global)\b|yarn\s+global\s+add|gem\s+install|brew\s+(?:install|uninstall|upgrade|reinstall)|pipx?\s+install|pip3\s+install|cargo\s+install|go\s+install)\b"#,
                   except: nil, decision: .ask, message: "This installs software for your whole Mac, not just this project."),
    ]

    /// The built-ins in the groups the Policies sheet shows them in.
    static let groups: [(title: String, ids: [String])] = [
        ("Production & deploys", ["ask-prod-console", "ask-deploy", "ask-prod-config", "ask-cloud-changes", "ask-env-dump"]),
        ("Git & GitHub", ["block-force-push-main", "ask-force-push", "ask-push-main", "ask-discard-changes", "ask-no-verify", "ask-pr-merge", "ask-github-changes"]),
        ("Data", ["ask-destructive-data"]),
        ("Secrets & files", ["block-private-keys", "ask-env-files", "ask-claude-settings", "ask-package-publish"]),
        ("Your Mac", ["block-rm-rf-home", "ask-rm-rf", "block-sudo", "block-curl-pipe-shell", "ask-system-changes", "ask-global-install"]),
    ]

    /// Built-ins that start switched off: things you do often enough that asking every time
    /// would get in the way. Switch them on if you want the check.
    static let offByDefault: Set<String> = ["ask-push-main", "ask-pr-merge", "ask-global-install", "ask-env-files"]

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

    /// Compiled patterns, reused: a history check runs every rule over thousands of calls.
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    /// A pattern that doesn't compile matches nothing.
    private static func found(_ pattern: String, in text: String) -> Bool {
        let re: NSRegularExpression
        if let cached = compiled.object(forKey: pattern as NSString) {
            re = cached
        } else {
            guard let made = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
            compiled.setObject(made, forKey: pattern as NSString)
            re = made
        }
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
