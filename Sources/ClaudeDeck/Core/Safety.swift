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

    /// The command Deck starts Claude with, typed into a shell (so ids must be session ids and the
    /// name is one quoted line). Nil if an id isn't one.
    static func launchCommand(_ launch: SessionLaunch) -> String? {
        for id in [launch.fork, launch.sessionId].compactMap({ $0 }) where !isSessionId(id) { return nil }
        let name = stripControls(launch.name, keepNewlines: false).trimmingCharacters(in: .whitespaces)
        var parts = ["claude"]
        if let fork = launch.fork { parts += ["--resume", fork, "--fork-session"] }
        if let id = launch.sessionId { parts += ["--session-id", id] }
        if !name.isEmpty { parts += ["--name", shellQuote(name)] }
        // Remote Control shows the session under its name in the Claude app.
        if launch.remoteControl { parts += ["--remote-control"] + (name.isEmpty ? [] : [shellQuote(name)]) }
        for dir in launch.addDirs { parts += ["--add-dir", shellQuote(dir)] }
        return parts.joined(separator: " ")
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
    /// `addDirs` are folders it may also read (Deck's attachments), quoted.
    static func resumeCommand(sessionId: String, originalArgs: [String], addDirs: [String] = []) -> String? {
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
        return (["claude", "--resume", sessionId] + kept + addDirs.flatMap { ["--add-dir", shellQuote($0)] }).joined(separator: " ")
    }

    static func typedTextAction(_ message: String) -> String {
        let clean = stripControls(message).replacingOccurrences(of: "\t", with: "    ")
        let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "text:" + escaped
    }
}

/// Taking a message out of Claude Code's input queue. It has no command for that: ↑ pulls every
/// queued message back into the input box, so Deck clears the box and retypes the ones to keep.
enum QueuedMessages {
    /// `queued` without one copy of `text`.
    static func without(_ text: String, in queued: [String]) -> [String] {
        var kept = queued
        if let i = kept.firstIndex(of: text) { kept.remove(at: i) }
        return kept
    }

    /// A pasted image is only a placeholder in the queue, so retyping the message would lose it.
    static func hasImage(_ message: String) -> Bool { message.contains("[Image #") }

    /// Empties the input box whatever its width: Ctrl+U clears one wrapped row, Backspace joins the
    /// next one. Spare presses do nothing. If Claude took the queue first, ↑ recalled an old prompt
    /// instead, hence the floor.
    static func clearAction(for queued: [String]) -> String {
        let rows = queued.reduce(0) { $0 + $1.count / 20 + $1.filter(\.isNewline).count + 1 }
        return "text:" + String(repeating: #"\x15\x7f"#, count: max(200, rows))
    }
}

/// How Deck starts Claude: a new session, or a fork of one, which starts with a copy of its
/// conversation while the original carries on unchanged. Both take the same options.
struct SessionLaunch: Equatable {
    /// The session to copy, for a fork.
    var fork: String? = nil
    /// Chosen up front, so Deck can pick out the new session once it starts.
    var sessionId: String? = nil
    var name = ""
    var remoteControl = false
    /// Folders it may also read: Deck's attachments, so it can open the images and files you send.
    var addDirs: [String] = []
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
