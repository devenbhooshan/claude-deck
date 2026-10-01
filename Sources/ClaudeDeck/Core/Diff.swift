import Foundation

struct DiffLine: Equatable {
    enum Kind: Equatable {
        case context, added, removed
        /// Stands in for unchanged lines left out between changes.
        case gap
    }

    let kind: Kind
    let text: String
}

enum LineDiff {
    /// A line diff by longest common subsequence. Very large inputs (where that gets slow) fall
    /// back to "all removed, all added", which is still correct, just less tidy.
    static func diff(old: String, new: String, maxCells: Int = 4_000_000) -> [DiffLine] {
        let a = lines(old), b = lines(new)
        if a.count * b.count > maxCells {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }
        // lcs[i][j] = length of the LCS of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                out.append(DiffLine(kind: .context, text: a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Removals before additions, as in a standard diff.
                out.append(DiffLine(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(DiffLine(kind: .added, text: b[j])); j += 1
            }
        }
        return out
    }

    /// Keeps `context` unchanged lines around each change; longer unchanged runs become one gap.
    static func compact(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind == .added || lines[$0].kind == .removed }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(lines.count - 1, c + context) { keep.insert(k) } }
        var out: [DiffLine] = []
        var skipped = 0
        for (i, line) in lines.enumerated() {
            if keep.contains(i) || line.kind == .gap {
                if skipped > 0 { out.append(gap(skipped)); skipped = 0 }
                out.append(line)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 && !out.isEmpty { out.append(gap(skipped)) }
        return out
    }

    static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    private static func gap(_ n: Int) -> DiffLine {
        DiffLine(kind: .gap, text: "⋯ \(n) unchanged line\(n == 1 ? "" : "s")")
    }

    private static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }
}

/// The change a file-editing tool call makes, as a compact line diff.
enum EditDiff {
    /// Diff for Edit (old_string → new_string), MultiEdit (each edit, separated by gaps) and
    /// Write (the whole new content, capped). Nil for other tools.
    static func lines(toolName: String, input: [String: Any], writeCap: Int = 400) -> [DiffLine]? {
        switch toolName {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return LineDiff.compact(LineDiff.diff(old: old, new: new))
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var out: [DiffLine] = []
            for edit in edits {
                let d = LineDiff.compact(LineDiff.diff(old: edit["old_string"] as? String ?? "",
                                                       new: edit["new_string"] as? String ?? ""))
                if !out.isEmpty && !d.isEmpty { out.append(DiffLine(kind: .gap, text: "⋯")) }
                out += d
            }
            return out
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            let all = content.isEmpty ? [] : content.components(separatedBy: "\n")
            var out = all.prefix(writeCap).map { DiffLine(kind: .added, text: $0) }
            if all.count > writeCap { out.append(DiffLine(kind: .gap, text: "⋯ \(all.count - writeCap) more lines")) }
            return out
        default:
            return nil
        }
    }
}
