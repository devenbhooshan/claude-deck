import Foundation

/// A skill Claude Code can use, from ~/.claude/skills, a project's .claude/skills, or a plugin.
struct Skill: Identifiable, Equatable {
    enum Scope: Equatable {
        case project, global, synced
        case plugin(String)
    }

    let name: String
    let description: String
    let scope: Scope
    let path: URL

    var id: String { "\(scopeLabel)/\(name)" }

    var scopeLabel: String {
        switch scope {
        case .project: "Project"
        case .global: "Global"
        case .synced: "claude.ai"
        case .plugin(let p): p
        }
    }

    /// What you type to use it: plugin skills are namespaced by their plugin.
    var command: String {
        if case .plugin(let p) = scope { return "/\(p):\(name)" }
        return "/\(name)"
    }
}

enum SkillCatalog {
    /// Project skills (the folder and its parents up to home), then global, then enabled plugins.
    static func load(projectDir: String?, home: String = NSHomeDirectory()) -> [Skill] {
        var found: [Skill] = []
        if let projectDir {
            for dir in projectDirs(from: projectDir, home: home) {
                found += skills(in: dir.appendingPathComponent(".claude/skills"), scope: .project)
            }
        }
        let globalDir = ClaudePaths.home.appendingPathComponent("skills")
        // skills/synced holds skills synced from your claude.ai account.
        found += skills(in: globalDir, scope: .global, skipping: ["synced"])
        found += skills(in: globalDir.appendingPathComponent("synced"), scope: .synced)
        for plugin in enabledPlugins() {
            found += skills(in: plugin.path.appendingPathComponent("skills"), scope: .plugin(plugin.name))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// `cwd` and each parent folder below `home`.
    static func projectDirs(from cwd: String, home: String) -> [URL] {
        var dirs: [URL] = []
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        while url.path.hasPrefix(homeURL.path + "/") {
            dirs.append(url)
            url = url.deletingLastPathComponent()
        }
        return dirs
    }

    /// Every folder (up to `depth` levels down, following symlinks) that holds a SKILL.md.
    static func skills(in dir: URL, scope: Skill.Scope, depth: Int = 3, skipping: Set<String> = []) -> [Skill] {
        let fm = FileManager.default
        guard depth > 0, let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Skill] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") && !skipping.contains(entry) {
            let sub = dir.appendingPathComponent(entry).resolvingSymlinksInPath()
            let file = sub.appendingPathComponent("SKILL.md")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let meta = frontmatter(text)
                out.append(Skill(name: meta["name"] ?? entry, description: meta["description"] ?? "",
                                 scope: scope, path: file))
            } else {
                out += skills(in: sub, scope: scope, depth: depth - 1)
            }
        }
        return out
    }

    /// The `key: value` pairs of a `---` header. Handles quotes and folded (`>` / `|`) values.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let piece = line.trimmingCharacters(in: .whitespaces)
                out[k] = (out[k]!.isEmpty ? "" : out[k]! + " ") + piece
                continue
            }
            key = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) {
                v = ""
                key = k
            } else if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }

    /// Installed plugins that are switched on (a plugin missing from enabledPlugins counts as on).
    static func enabledPlugins() -> [(name: String, path: URL)] {
        let registry = ClaudePaths.home.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: registry),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = obj["plugins"] as? [String: [[String: Any]]] else { return [] }
        let settings = (try? Data(contentsOf: ClaudePaths.home.appendingPathComponent("settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let enabled = settings?["enabledPlugins"] as? [String: Bool] ?? [:]
        return plugins.keys.sorted().compactMap { key in
            guard enabled[key] ?? true, let path = plugins[key]?.last?["installPath"] as? String else { return nil }
            return (String(key.split(separator: "@")[0]), URL(fileURLWithPath: path))
        }
    }
}

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
