import Foundation

/// Adding and removing Deck's hooks in ~/.claude/settings.json, keeping everything else in it.
enum ClaudeSettings {
    static var url: URL { ClaudePaths.home.appendingPathComponent("settings.json") }

    /// Whether the settings mention `marker` (a hook command Deck added).
    static func contains(_ marker: String) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) ?? false
    }

    static func addHook(event: String, command: String) throws {
        try edit { hooks in
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
    }

    /// Removes every hook for `event` whose command contains `marker`, and entries left empty.
    static func removeHooks(event: String, containing marker: String) throws {
        try edit { hooks in
            let entries = (hooks[event] as? [[String: Any]] ?? []).compactMap { entry -> [String: Any]? in
                var entry = entry
                let kept = (entry["hooks"] as? [[String: Any]] ?? [])
                    .filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if kept.isEmpty { return nil }
                entry["hooks"] = kept
                return entry
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }
    }

    /// Backs the file up, then rewrites it with `change` applied to its "hooks". Writes through a
    /// symlinked settings file (dotfiles setups) instead of replacing the link.
    private static func edit(_ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        let url = url.resolvingSymlinksInPath()
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ClaudeDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object"])
            }
            settings = obj
            let backup = url.appendingPathExtension("claudedeck-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// Deck's policy checker as a `PreToolUse` hook, so it runs before every tool call in every session.
enum PolicyHook {
    static var isInstalled: Bool { ClaudeSettings.contains(Policies.checkerName) }

    static func command(checker: URL) -> String { Safety.shellQuote(checker.path) }

    /// Adds the hook for `checker`, replacing one added before (say, from another copy of Deck).
    static func install(checker: URL) throws {
        try ClaudeSettings.removeHooks(event: "PreToolUse", containing: Policies.checkerName)
        try ClaudeSettings.addHook(event: "PreToolUse", command: command(checker: checker))
    }

    static func uninstall() throws {
        try ClaudeSettings.removeHooks(event: "PreToolUse", containing: Policies.checkerName)
    }
}
