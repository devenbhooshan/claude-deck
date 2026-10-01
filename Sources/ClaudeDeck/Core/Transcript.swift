import AppKit
import Foundation
import ImageIO

enum ClaudePaths {
    /// Claude Code's data folder. Tests point this at a temporary folder.
    nonisolated(unsafe) static var home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static var sessions: URL { home.appendingPathComponent("sessions") }
    static var projects: URL { home.appendingPathComponent("projects") }

    /// Transcripts live at ~/.claude/projects/<encoded cwd>/<sessionId>.jsonl.
    static func transcript(for sessionId: String, cwd: String?) -> URL? {
        let fm = FileManager.default
        if let cwd {
            let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let url = projects.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return nil }
        for dir in dirs {
            let url = projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Reads complete lines from the end of a file without loading all of it.
enum TailReader {
    static func read(_ url: URL, from offset: UInt64?, maxBytes: UInt64) -> (lines: [Data], end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else {
            return ([], offset ?? 0)
        }
        defer { try? handle.close() }
        // A fresh read, or the file shrank below our offset (rewritten): read the last maxBytes.
        let fresh = offset.map { $0 > size } ?? true
        let start = fresh ? (size > maxBytes ? size - maxBytes : 0) : offset!
        // Starting mid-file, include the byte before `start` so we can tell whether the first
        // line is complete; the (possibly empty) piece before the first newline is then dropped.
        let midFile = fresh && start > 0
        try? handle.seek(toOffset: midFile ? start - 1 : start)
        let data = (try? handle.readToEnd()) ?? Data()

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        if midFile { lines.removeFirst() }
        // Keep the trailing partial line for the next read.
        var consumed = UInt64(data.count) - (midFile ? 1 : 0)
        if data.last != UInt8(ascii: "\n"), let last = lines.popLast() {
            consumed -= UInt64(last.count)
        }
        return (lines.filter { !$0.isEmpty }, start + consumed)
    }
}

/// Incrementally parses a session transcript into display items.
/// Only touched from TranscriptModel's serial queue.
final class TranscriptParser: @unchecked Sendable {
    private(set) var items: [TranscriptItem] = []
    private(set) var results: [String: ToolResult] = [:]
    private(set) var title: String?
    private var hasCustomTitle = false
    /// Claude Code's input queue, mirrored from queue-operation records (system notifications included,
    /// since `dequeue` pops the oldest entry whatever it is).
    private var queue: [String] = []

    /// Messages typed while Claude was busy and not yet picked up.
    var queued: [String] { queue.filter { !$0.hasPrefix("<") } }
    private var offset: UInt64?
    private var counter = 0
    let url: URL

    static let maxItems = 600

    init(url: URL) { self.url = url }

    /// Returns true if anything new was read.
    @discardableResult
    func refresh() -> Bool {
        let (lines, end) = TailReader.read(url, from: offset, maxBytes: 4_000_000)
        let changed = end != offset
        offset = end
        for line in lines { ingest(line) }
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        return changed && !lines.isEmpty
    }

    /// The most recent tool call that has no result yet: what a permission prompt is asking about.
    var pendingTool: (name: String, summary: String)? {
        for item in items.reversed() {
            if case let .tool(call) = item.kind {
                return results[call.id] == nil ? (call.name, call.summary) : nil
            }
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func ingest(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !hasCustomTitle { title = t }
            return
        case "custom-title":
            if let t = obj["customTitle"] as? String ?? obj["title"] as? String {
                title = t
                hasCustomTitle = true
            }
            return
        case "queue-operation":
            // Prompts sent while Claude is busy are queued, then absorbed mid-turn as an attachment.
            let content = obj["content"] as? String
            switch obj["operation"] as? String {
            case "enqueue":
                if let content { queue.append(content) }
            case "dequeue":
                // Pops the oldest entry; it carries no content.
                if !queue.isEmpty { queue.removeFirst() }
            case "popAll":
                queue.removeAll()
            case "remove":
                if let content, let i = queue.firstIndex(of: content) { queue.remove(at: i) }
            default:
                break
            }
            return
        case "user", "assistant", "attachment":
            break
        default:
            return
        }
        if obj["isSidechain"] as? Bool == true { return }
        let isMeta = obj["isMeta"] as? Bool == true
        let ts = (obj["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString

        func add(_ kind: TranscriptItem.Kind) {
            counter += 1
            items.append(TranscriptItem(id: "\(uuid)-\(counter)", kind: kind, timestamp: ts))
        }

        if type == "attachment" {
            if let att = obj["attachment"] as? [String: Any], att["type"] as? String == "queued_command",
               (att["origin"] as? [String: Any])?["kind"] as? String == "human" {
                addUser(att["prompt"], add)
            }
            return
        }
        guard let message = obj["message"] as? [String: Any] else { return }

        if type == "user" {
            if !isMeta { addUser(message["content"], add) }
            // Tool results ride along in user messages; fall through to collect them.
        } else if let text = message["content"] as? String {
            add(.assistant(text))
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard type == "assistant", let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                add(.assistant(text))
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "tool"
                add(.tool(ToolCall(id: id, name: name, summary: Self.summarize(name: name, input: block["input"]))))
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                results[id] = ToolResult(text: Self.resultText(block["content"]),
                                         isError: block["is_error"] as? Bool == true)
            default:
                continue
            }
        }
    }

    /// A user prompt is either a string or blocks of text and images.
    private func addUser(_ content: Any?, _ add: (TranscriptItem.Kind) -> Void) {
        if let text = content as? String, let i = queue.firstIndex(of: text) { queue.remove(at: i) }
        if let text = content as? String {
            if let kind = Self.userKind(text) { add(kind) }
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        var texts: [String] = []
        var images: [NSImage] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { texts.append(t) }
            case "image":
                if let source = block["source"] as? [String: Any], let b64 = source["data"] as? String,
                   let data = Data(base64Encoded: b64), let thumb = Self.thumbnail(data) {
                    images.append(thumb)
                }
            default:
                continue
            }
        }
        let joined = texts.joined(separator: "\n")
        if images.isEmpty {
            if !texts.isEmpty, let kind = Self.userKind(joined) { add(kind) }
            return
        }
        // Drop the "[Image #N]" placeholders; the thumbnails replace them.
        let cleaned = joined.replacingOccurrences(of: #"\[Image #\d+\]\s?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        add(.user(cleaned, images: images))
    }

    /// Downsampled once at parse time (max 640px), at 2x for Retina.
    static func thumbnail(_ data: Data, maxPixels: Int = 640) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    private static func userKind(_ raw: String) -> TranscriptItem.Kind? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<system-reminder>") || text.hasPrefix("Caveat:") { return nil }
        if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
            let name = between(text, "<command-name>", "</command-name>") ?? ""
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            return .command([name, args].filter { !$0.isEmpty }.joined(separator: " "))
        }
        if text.hasPrefix("<local-command-stdout>") {
            let out = between(text, "<local-command-stdout>", "</local-command-stdout>") ?? ""
            return out.isEmpty ? nil : .notice(out)
        }
        if text.hasPrefix("<task-notification>") {
            let status = between(text, "<status>", "</status>") ?? "completed"
            let summary = between(text, "<summary>", "</summary>") ?? "Background task \(status)"
            return .taskEvent(summary, ok: status == "completed")
        }
        if text.hasPrefix("[Request interrupted") { return .notice("Interrupted") }
        return .user(text, images: [])
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(name: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        let keys = ["command", "file_path", "pattern", "url", "query", "description", "prompt", "path", "skill"]
        for key in keys {
            if let v = input[key] as? String, !v.isEmpty { return truncate(v, 300) }
        }
        // `input` was itself parsed from JSON, so it always serializes back.
        let json = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return truncate(String(decoding: json, as: UTF8.self), 300)
    }

    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return truncate(s, 8000) }
        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { b -> String? in
                if let t = b["text"] as? String { return t }
                if b["type"] as? String == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
            return truncate(text, 8000)
        }
        return ""
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}
