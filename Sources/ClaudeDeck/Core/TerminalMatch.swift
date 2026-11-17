import Foundation

struct GhosttyTerminal: Equatable {
    let id: String
    let name: String
    let workingDirectory: String
}

/// Finds the Ghostty terminal running a Claude Code session.
enum TerminalMatch {
    // Claude Code prefixes the terminal title with an idle mark or a spinner frame.
    // ("*" is left out: shells and editors use it too.)
    static let claudeMarks: Set<Character> = ["✳", "✻", "✶", "✢", "✽", "·", "◐", "◓", "◑", "◒"]
    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    /// Parses our AppleScript's output: records split by RS, fields (id, name, working directory)
    /// by US. These can't appear in titles, unlike tabs and newlines, so a title can't forge a row.
    static func parse(_ output: String) -> [GhosttyTerminal] {
        output.components(separatedBy: recordSeparator).compactMap { line in
            let parts = line.components(separatedBy: fieldSeparator)
            guard parts.count >= 3 else { return nil }
            return GhosttyTerminal(id: parts[0], name: parts[1], workingDirectory: parts[2])
        }
    }

    static func isClaudeTitle(_ name: String) -> Bool {
        name.first.map { claudeMarks.contains($0) || isBraille($0) } ?? false
    }

    static func strippedTitle(_ name: String) -> String {
        var s = Substring(name)
        while let c = s.first, claudeMarks.contains(c) || isBraille(c) || c == " " { s = s.dropFirst() }
        return String(s)
    }

    static func isBraille(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2800...0x28FF).contains(v)
    }

    /// A Claude terminal in the session's folder. In order: the terminal Deck opened for this
    /// session (`preferred`), the one with its title, the only Claude terminal in the folder, or
    /// the only one no other session has claimed. Titles alone are never trusted (any program can
    /// set one), and anything ambiguous returns nil.
    static func find(for session: Session, in all: [GhosttyTerminal], claimed: Set<String> = [],
                     preferred: String? = nil) -> GhosttyTerminal? {
        let inDir = all.filter { stillMatches($0, session: session) }
        if let preferred, let t = inDir.first(where: { $0.id == preferred }) { return t }
        let free = inDir.filter { !claimed.contains($0.id) }
        let names = [session.title, session.name].compactMap { $0 }.filter { !$0.isEmpty }
        let titled = free.filter { names.contains(strippedTitle($0.name)) }
        if titled.count == 1 { return titled[0] }
        if inDir.count == 1 { return inDir[0] }
        return free.count == 1 ? free[0] : nil
    }

    /// Whether a terminal still looks like this session's (checked right before every action).
    static func stillMatches(_ t: GhosttyTerminal, session: Session) -> Bool {
        isClaudeTitle(t.name) && folders(of: session.cwd).contains(t.workingDirectory)
    }

    /// The folders the session's terminal can be in: the session's own, and, when Claude moved the
    /// session into a worktree (`<repo>/.claude/worktrees/<name>`), the repo it was started in, which
    /// the terminal keeps reporting. Only that exact layout: any parent folder would let a terminal
    /// sitting in ~ pass for every session.
    static func folders(of cwd: String) -> [String] {
        let marker = "/.claude/worktrees/"
        guard let r = cwd.range(of: marker), !cwd[r.upperBound...].isEmpty,
              !cwd[r.upperBound...].contains("/") else { return [cwd] }
        return [cwd, String(cwd[..<r.lowerBound])]
    }

    /// `folders(of:)` as one AppleScript argument, split by `fieldSeparator` in the script.
    static func foldersArgument(_ cwd: String) -> String { folders(of: cwd).joined(separator: fieldSeparator) }
}
