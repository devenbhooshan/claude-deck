import Foundation

/// Anything you can type after "/" in Claude Code: a built-in, a custom command, or a skill.
struct SlashCommand: Identifiable, Equatable {
    /// How Deck handles a command.
    enum Kind: Equatable {
        /// Typed into the session; any output lands in the transcript.
        case send
        /// Typed into the session, where it opens an interactive menu: Deck brings the terminal forward.
        case terminal
        /// Handled by Deck itself.
        case deck
    }

    let command: String      // "/review", "/frontend:design"
    let description: String
    let source: String       // "Built-in", "Project", "Global", "claude.ai", a plugin name
    var kind: Kind = .send

    var id: String { command }
}

enum CommandCatalog {
    /// Claude Code's built-in commands that make sense to send from Deck.
    static let builtIns: [SlashCommand] = [
        ("/usage", "Plan usage limits (shown in Deck)", SlashCommand.Kind.deck),
        ("/clear", "Start a fresh conversation", .send),
        ("/compact", "Summarize the conversation to free up context", .send),
        ("/context", "Show what's using the context window", .send),
        ("/cost", "Show token usage and cost for this session", .send),
        ("/rename", "Rename this session", .send),
        ("/review", "Review a pull request", .send),
        ("/init", "Create a CLAUDE.md for this project", .send),
        ("/model", "Switch the model", .terminal),
        ("/memory", "Edit Claude's memory files", .terminal),
        ("/mcp", "Manage MCP servers", .terminal),
        ("/agents", "Manage subagents", .terminal),
        ("/permissions", "View or change tool permissions", .terminal),
        ("/hooks", "Manage hooks", .terminal),
        ("/status", "Show version, model and account", .terminal),
        ("/config", "Open settings", .terminal),
        ("/doctor", "Check the Claude Code installation", .terminal),
        ("/help", "Show help", .terminal),
    ].map { SlashCommand(command: $0.0, description: $0.1, source: "Built-in", kind: $0.2) }

    /// How to handle a message before sending it: built-ins by their kind (`/model sonnet`
    /// with an argument just switches, so it's sent), everything else is sent as-is.
    static func kind(of message: String) -> SlashCommand.Kind {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .send }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let builtIn = builtIns.first(where: { $0.command == String(parts[0]) }) else { return .send }
        if builtIn.kind == .terminal && parts.count > 1 && builtIn.command == "/model" { return .send }
        return builtIn.kind
    }

    /// Custom commands (project, then global, then plugins), then skills, then built-ins.
    /// The first one with a given name wins, as in Claude Code.
    static func all(skills: [Skill], projectDir: String?, home: String = NSHomeDirectory()) -> [SlashCommand] {
        var found: [SlashCommand] = []
        if let projectDir {
            for dir in SkillCatalog.projectDirs(from: projectDir, home: home) {
                found += commands(in: dir.appendingPathComponent(".claude/commands"), source: "Project")
            }
        }
        found += commands(in: ClaudePaths.home.appendingPathComponent("commands"), source: "Global")
        for plugin in SkillCatalog.enabledPlugins() {
            found += commands(in: plugin.path.appendingPathComponent("commands"), source: plugin.name, namespace: plugin.name)
        }
        found += skills.map { SlashCommand(command: $0.command, description: $0.description, source: $0.scopeLabel) }
        found += builtIns
        var seen = Set<String>()
        return found.filter { seen.insert($0.command).inserted }
    }

    /// `*.md` files become commands; subfolders become namespaces ("frontend/review.md" → "/frontend:review").
    static func commands(in dir: URL, source: String, namespace: String? = nil, depth: Int = 3) -> [SlashCommand] {
        guard depth > 0, let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [SlashCommand] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let url = dir.appendingPathComponent(entry)
            if entry.hasSuffix(".md") {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let name = String(entry.dropLast(3))
                let full = namespace.map { "\($0):\(name)" } ?? name
                out.append(SlashCommand(command: "/" + full, description: describe(text), source: source))
            } else {
                let ns = namespace.map { "\($0):\(entry)" } ?? entry
                out += commands(in: url, source: source, namespace: ns, depth: depth - 1)
            }
        }
        return out
    }

    /// The frontmatter description, or else the first line of text (minus heading marks).
    static func describe(_ text: String) -> String {
        if let d = SkillCatalog.frontmatter(text)["description"], !d.isEmpty { return d }
        var lines = ArraySlice(text.components(separatedBy: "\n"))
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst().drop { $0.trimmingCharacters(in: .whitespaces) != "---" }.dropFirst()
        }
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    /// The command being typed: the text after a leading "/" until the first space, or nil.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// Commands matching `query`: name prefixes first, then names containing it, then descriptions.
    static func matches(_ query: String, in all: [SlashCommand], limit: Int = 50) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(all.prefix(limit)) }
        func name(_ c: SlashCommand) -> String { String(c.command.dropFirst()).lowercased() }
        let prefix = all.filter { name($0).hasPrefix(q) || name($0).split(separator: ":").last!.hasPrefix(q) }
        let contains = all.filter { name($0).contains(q) && !prefix.contains($0) }
        let described = all.filter { $0.description.lowercased().contains(q) && !prefix.contains($0) && !contains.contains($0) }
        return Array((prefix + contains + described).prefix(limit))
    }
}
