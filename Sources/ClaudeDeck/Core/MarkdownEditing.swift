import Foundation

/// The editor's text operations, kept apart from the text view so they can be tested.
/// Ranges are UTF-16. Each edit is (range to replace, replacement, selection afterwards).
enum MarkdownEditing {
    struct Edit: Equatable {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    /// Clicking a task's `[ ]` checks it; clicking `[x]` unchecks it.
    static func toggleTask(at location: Int, in text: String) -> Edit? {
        let ns = text as NSString
        guard location < ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
        guard let m = MarkdownSyntax.listItem.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
              m.range(at: 4).location != NSNotFound else { return nil }
        let box = NSRange(location: line.location + m.range(at: 4).location, length: 3)
        guard NSLocationInRange(location, box) else { return nil }
        let done = ns.substring(with: box) != "[ ]"
        return Edit(range: box, text: done ? "[ ]" : "[x]", selection: NSRange(location: NSMaxRange(box), length: 0))
    }

    /// Wraps the selection in `marker` (`**` bold, `*` italic, `` ` `` code), or unwraps it if it's
    /// already wrapped. With nothing selected it leaves the cursor between a new pair.
    static func wrap(_ range: NSRange, in text: String, with marker: String) -> Edit {
        let ns = text as NSString
        let m = (marker as NSString).length
        let selected = ns.substring(with: range)
        if range.location >= m, NSMaxRange(range) + m <= ns.length,
           ns.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker {
            return Edit(range: NSRange(location: range.location - m, length: range.length + 2 * m), text: selected,
                        selection: NSRange(location: range.location - m, length: range.length))
        }
        if range.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: range.length - 2 * m))
            return Edit(range: range, text: inner, selection: NSRange(location: range.location, length: range.length - 2 * m))
        }
        return Edit(range: range, text: marker + selected + marker,
                    selection: NSRange(location: range.location + m, length: range.length))
    }

    /// Makes the selection a link and selects the address to type over.
    static func link(_ range: NSRange, in text: String) -> Edit {
        let selected = (text as NSString).substring(with: range)
        let address = "https://"
        return Edit(range: range, text: "[\(selected)](\(address))",
                    selection: NSRange(location: range.location + (selected as NSString).length + 3,
                                       length: (address as NSString).length))
    }

    /// Return at the end of a list item starts the next one (numbered, and unchecked for tasks);
    /// Return on an empty item ends the list. Nil: an ordinary new line.
    static func newline(at location: Int, in text: String) -> Edit? {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
        let end = line.location + (content as NSString).length
        guard location == end,
              let m = MarkdownSyntax.listItem.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length))
        else { return nil }
        let part = { (i: Int) -> String in
            m.range(at: i).location == NSNotFound ? "" : (content as NSString).substring(with: m.range(at: i))
        }
        if part(5).trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: NSRange(location: line.location, length: end - line.location), text: "",
                        selection: NSRange(location: line.location, length: 0))
        }
        var marker = part(2)
        if let n = Int(marker.dropLast()) { marker = "\(n + 1)\(marker.last!)" }
        let next = "\n" + part(1) + marker + part(3) + (part(4).isEmpty ? "" : "[ ] ")
        return Edit(range: NSRange(location: location, length: 0), text: next,
                    selection: NSRange(location: location + (next as NSString).length, length: 0))
    }

    /// The lines (from 1) a selection covers.
    static func lines(of range: NSRange, in text: String) -> ClosedRange<Int> {
        let ns = text as NSString
        func line(_ location: Int) -> Int {
            var n = 1
            for i in 0..<min(location, ns.length) where ns.character(at: i) == 10 { n += 1 }
            return n
        }
        let start = line(range.location)
        return start...line(max(range.location, NSMaxRange(range) - 1))
    }

    /// A message to the session about part of a file: where it is, the passage quoted, then your note.
    static func feedback(path: String, cwd: String, lines: ClosedRange<Int>, excerpt: String, note: String) -> String {
        let shown = !cwd.isEmpty && path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
        let at = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        let quoted = excerpt.trimmingCharacters(in: .newlines).components(separatedBy: "\n").map { "> " + $0 }
        return "In \(shown), \(at):\n\(quoted.joined(separator: "\n"))\n\n\(note.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    enum DiskChange: Equatable {
        /// Nothing new: what you have, or what you last saved (your own save, seen after you typed on).
        case same
        /// You had no unsaved edits: show the new text.
        case reload
        /// It changed under your unsaved edits: ask.
        case conflict
    }

    static func diskChanged(saved: String, current: String, disk: String) -> DiskChange {
        if disk == current || disk == saved { return .same }
        return current == saved ? .reload : .conflict
    }
}
