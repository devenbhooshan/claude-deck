import Foundation

enum TranscriptExport {
    /// The conversation as Markdown, for Copy Transcript.
    static func markdown(title: String, blocks: [TranscriptBlock]) -> String {
        var out = ["# \(title)"]
        for block in blocks {
            switch block {
            case .tools(let calls):
                out.append(calls.map { "- `\($0.name)`: `\($0.summary.replacingOccurrences(of: "\n", with: " "))`" }
                    .joined(separator: "\n"))
            case .item(let item):
                switch item.kind {
                case let .user(text, images):
                    let note = images.isEmpty ? "" : " _(\(images.count) image\(images.count == 1 ? "" : "s"))_"
                    out.append("**You:**\(note) \(text)")
                case .command(let c): out.append("**You:** `\(c.hasPrefix("/") ? c : "/" + c)`")
                case .assistant(let t): out.append("**Claude:** \(t)")
                case .notice(let t): out.append("_\(t)_")
                case .commandOutput(let t): out.append("```\n\(t)\n```")
                case .taskEvent(let t, _): out.append("_\(t)_")
                case .tool: break
                }
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// Drops "Sending…" bubbles once the transcript shows the real message (queued or sent),
    /// or after `timeout` so a lost message can't linger forever.
    static func reconcile(_ outgoing: [OutgoingMessage], queued: [String], blocks: [TranscriptBlock],
                          now: Date = Date(), timeout: TimeInterval = 20) -> [OutgoingMessage] {
        guard !outgoing.isEmpty else { return outgoing }
        var seen = queued
        for block in blocks.suffix(30) {
            if case .item(let item) = block, case let .user(text, _) = item.kind { seen.append(text) }
        }
        return outgoing.filter { o in
            let needle = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let arrived = !needle.isEmpty && seen.contains { $0.contains(needle) }
            return !arrived && now.timeIntervalSince(o.sentAt) <= timeout
        }
    }
}
