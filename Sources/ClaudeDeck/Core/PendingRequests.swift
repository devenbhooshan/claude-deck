import Foundation

/// Details of permission prompts, captured by a Claude Code `PermissionRequest` hook.
///
/// The transcript only records a tool call after it runs, so while a prompt is open the
/// transcript can't say what it's asking. The hook writes the request (tool_name, tool_input)
/// to a file here just before Claude shows the dialog. It only observes; it never answers.
enum PendingRequests {
    /// Where the hook drops requests. Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.devenbhooshan.claudedeck/pending")

    static var settingsURL: URL { ClaudePaths.home.appendingPathComponent("settings.json") }
    private static let marker = "com.devenbhooshan.claudedeck/pending"

    /// Writes stdin to a unique file and prints nothing, so Claude's normal dialog still appears.
    static var hookCommand: String {
        let d = "$HOME/Library/Caches/\(marker)"
        return "mkdir -p \"\(d)\" && cat > \"$(mktemp \"\(d)/req.XXXXXX\")\""
    }

    struct Request {
        let date: Date
        let tool: ToolCall
    }

    /// The newest request per session id. Files older than a day are deleted.
    static func load() -> [String: Request] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }
        var newest: [String: Request] = [:]
        for f in files {
            guard let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if Date().timeIntervalSince(date) > 86400 { try? fm.removeItem(at: f); continue }
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = obj["session_id"] as? String,
                  let name = obj["tool_name"] as? String else { continue }
            if let existing = newest[session], existing.date > date { continue }
            let summary = describe(name: name, input: obj["tool_input"])
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let diff = EditDiff.lines(toolName: name, input: input)
            // An edit is shown as its diff, so the summary only needs to name the file.
            let shown = diff != nil ? (input["file_path"] as? String ?? summary) : summary
            newest[session] = Request(date: date, tool: ToolCall(id: f.lastPathComponent, name: name, summary: shown, diff: diff))
        }
        return newest
    }

    /// The full request, for approving: a Bash command or file path as-is, anything else (MCP tools
    /// etc.) as all of its parameters, so no field can hide behind a harmless-looking one.
    static func describe(name: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        // A request that is just one command/path/URL (plus harmless options) shows it plainly.
        let harmless: Set<String> = ["description", "timeout", "run_in_background"]
        for key in ["command", "file_path", "url", "pattern"] {
            if let v = input[key] as? String, Set(input.keys).subtracting(harmless).subtracting([key]).isEmpty {
                return v
            }
        }
        let json = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: json, as: UTF8.self)
    }

    /// Deletes captured requests for sessions that are no longer waiting: they hold full commands
    /// and file contents, so they shouldn't outlive the prompt.
    static func prune(keeping waitingSessions: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let session = (try? Data(contentsOf: f))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["session_id"] as? String
            if session.map({ !waitingSessions.contains($0) }) ?? true { try? fm.removeItem(at: f) }
        }
    }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Adds the hook to ~/.claude/settings.json (after backing it up). Running sessions pick it up live.
    static func install() throws {
        let fm = FileManager.default
        // Write through a symlinked settings file (dotfiles setups) instead of replacing the link.
        let settingsURL = settingsURL.resolvingSymlinksInPath()
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ClaudeDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object"])
            }
            settings = obj
            let backup = settingsURL.appendingPathExtension("claudedeck-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        entries.append(["matcher": "", "hooks": [["type": "command", "command": hookCommand]]])
        hooks["PermissionRequest"] = entries
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
