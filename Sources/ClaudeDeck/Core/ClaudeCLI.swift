import Foundation

/// Finds the `claude` command. Apps launched from Finder don't get your shell's PATH.
enum ClaudeCLI {
    static func locate(candidates: [String] = defaultCandidates,
                       isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        candidates.first(where: isExecutable)
    }

    static var defaultCandidates: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }
}
