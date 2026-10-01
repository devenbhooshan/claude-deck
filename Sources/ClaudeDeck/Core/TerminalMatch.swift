import Foundation

struct GhosttyTerminal: Equatable {
    let id: String
    let name: String
    let workingDirectory: String
}

/// Finds the Ghostty terminal running a Claude Code session.
enum TerminalMatch {
    // Claude Code prefixes the terminal title with an idle mark or a spinner frame.
    static let claudeMarks: Set<Character> = ["✳", "✻", "✶", "✢", "✽", "·", "*", "◐", "◓", "◑", "◒"]

    /// Parses the tab-separated "id, name, working directory" lines our AppleScript prints.
    static func parse(_ output: String) -> [GhosttyTerminal] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
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

    /// Matches by Claude's title first (it mirrors the transcript's title), then by working
    /// directory when exactly one Claude terminal is in that folder.
    static func find(for session: Session, in all: [GhosttyTerminal]) -> GhosttyTerminal? {
        let claude = all.filter { isClaudeTitle($0.name) }
        if let title = session.title, !title.isEmpty {
            let titled = claude.filter { strippedTitle($0.name) == title }
            if let t = titled.first(where: { $0.workingDirectory == session.cwd }) ?? (titled.count == 1 ? titled.first : nil) {
                return t
            }
        }
        let inDir = claude.filter { $0.workingDirectory == session.cwd }
        return inDir.count == 1 ? inDir[0] : nil
    }
}
