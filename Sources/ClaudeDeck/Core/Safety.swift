import Foundation

/// Guards for anything Deck types or runs on your behalf.
enum Safety {
    /// Claude Code session ids are UUIDs. Anything else is refused before it reaches a shell.
    static func isSessionId(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                options: .regularExpression) != nil
    }

    /// POSIX single-quoting: safe to paste into any shell.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The command a new session starts with. With Remote Control you can also drive it from the
    /// Claude app or claude.ai; its name is typed into a shell, so it's one quoted line.
    static func newSessionCommand(remoteControl: Bool, name: String = "") -> String {
        guard remoteControl else { return "claude" }
        let name = stripControls(name, keepNewlines: false).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "claude --remote-control" : "claude --remote-control \(shellQuote(name))"
    }

    /// Removes terminal colour/format escape sequences (ESC [ … letter).
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// Removes control characters (escape sequences, bracketed-paste markers, etc.), keeping newlines and tabs.
    static func stripControls(_ s: String, keepNewlines: Bool = true) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            if keepNewlines && (scalar == "\n" || scalar == "\t") { return true }
            return !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value))
        }))
    }

    /// Encodes a message for Ghostty's `text:` action, which types it rather than pasting it, so
    /// Claude Code treats it as typed input. The action takes a Zig string literal: backslashes are
    /// escaped, and each newline is sent as Ctrl+J (`\n`), Claude Code's "new line without sending".
    /// The command that brings a session back after a restart: `claude --resume <id>`, keeping
    /// only well-known launch flags from how it was started (values limited to plain words), so
    /// nothing from the old command line can inject shell syntax.
    static func resumeCommand(sessionId: String, originalArgs: [String]) -> String? {
        guard isSessionId(sessionId) else { return nil }
        let switches: Set<String> = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                                     "--verbose", "--chrome", "--ide"]
        let valued: Set<String> = ["--model", "--permission-mode"]
        let word = #"^[A-Za-z0-9._:\[\]-]+$"#
        var kept: [String] = []
        var i = 0
        while i < originalArgs.count {
            let arg = originalArgs[i]
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if switches.contains(arg) {
                kept.append(arg)
            } else if valued.contains(parts[0]) {
                let value = parts.count == 2 ? parts[1] : (i + 1 < originalArgs.count ? originalArgs[i + 1] : "")
                if parts.count == 1 { i += 1 }
                if value.range(of: word, options: .regularExpression) != nil { kept += [parts[0], shellQuote(value)] }
            }
            i += 1
        }
        return (["claude", "--resume", sessionId] + kept).joined(separator: " ")
    }

    static func typedTextAction(_ message: String) -> String {
        let clean = stripControls(message).replacingOccurrences(of: "\t", with: "    ")
        let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "text:" + escaped
    }
}

/// When Deck may answer or type into a session, decided from a fresh read of its record.
enum PromptGuard {
    /// Typing a message is only safe at Claude's prompt: never while a dialog is open, where
    /// Return would pick the highlighted option.
    static func canType(_ record: SessionRecord?) -> Bool {
        guard let record else { return false }
        return record.status != "waiting"
    }

    /// Restarting quits Claude, so only between steps: never mid-work or with a dialog open.
    static func canRestart(_ record: SessionRecord?) -> Bool {
        record?.status == "idle"
    }

    /// Ending quits Claude: at its prompt, including while a background task runs (which stops it).
    static func canEnd(_ record: SessionRecord?) -> Bool {
        record?.status == "idle" || record?.status == "shell"
    }

    /// Esc stops Claude only while it's working; at the prompt it would clear what's typed there.
    static func canInterrupt(_ record: SessionRecord?) -> Bool {
        record?.status == "busy"
    }

    /// Answering is only safe for the prompt you were shown: still waiting, and the same one
    /// (its status hasn't changed since).
    static func canAnswer(_ record: SessionRecord?, expectedSince: Double?) -> Bool {
        guard let record, record.status == "waiting" else { return false }
        guard let expectedSince else { return true }
        // Timestamps are milliseconds; allow for the round trip through Date.
        return record.statusUpdatedAt.map { abs($0 - expectedSince) < 1 } ?? false
    }

    /// Tools whose permission dialog is the standard Yes / Yes-and-don't-ask / No, so Return means
    /// "allow once" and 2 means "always". Others (plan approval, questions) differ: answer in the terminal.
    /// Whether Deck can answer this prompt with one click: it knows exactly what's being asked,
    /// and the dialog's options mean what the buttons say.
    static func canAnswerHere(_ s: Session) -> Bool {
        guard SessionNav.isPermission(s), let tool = s.pendingTool else { return false }
        return hasStandardDialog(tool.name)
    }

    static func hasStandardDialog(_ toolName: String) -> Bool {
        let standard: Set<String> = ["Bash", "Edit", "MultiEdit", "Write", "NotebookEdit", "WebFetch", "WebSearch",
                                     "Read", "Glob", "Grep", "Skill", "Agent", "Task"]
        return standard.contains(toolName) || toolName.hasPrefix("mcp__")
    }
}
