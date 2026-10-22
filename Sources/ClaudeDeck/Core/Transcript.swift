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
        let (lines, end) = readLines(url, from: offset, maxBytes: maxBytes)
        return (lines.map(\.data), end)
    }

    /// Like `read`, with where each line starts in the file.
    static func readLines(_ url: URL, from offset: UInt64?, maxBytes: UInt64) -> (lines: [(offset: UInt64, data: Data)], end: UInt64) {
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

        var lines = split(data, at: midFile ? start - 1 : start)
        if midFile { lines.removeFirst() }
        // Keep the trailing partial line for the next read.
        var consumed = UInt64(data.count) - (midFile ? 1 : 0)
        if data.last != UInt8(ascii: "\n"), let last = lines.popLast() {
            consumed -= UInt64(last.data.count)
        }
        return (lines.filter { !$0.data.isEmpty }, start + consumed)
    }

    /// The complete lines just before `end` (a line start): at least one if there are any,
    /// reading further back as needed, since a line with images can be megabytes long.
    static func lines(before end: UInt64, in url: URL, chunk: UInt64) -> [(offset: UInt64, data: Data)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var size = chunk
        var start: UInt64
        var lines: [(offset: UInt64, data: Data)]
        repeat {
            start = end > size ? end - size : 0
            // From the byte before `start`, so a line cut at the start can be told apart and dropped.
            let from = start > 0 ? start - 1 : 0
            try? handle.seek(toOffset: from)
            let data = (try? handle.read(upToCount: Int(end - from))) ?? Data()
            lines = split(data, at: from)
            if start > 0 { lines.removeFirst() }
            lines = lines.filter { !$0.data.isEmpty }
            size *= 2
        } while start > 0 && lines.isEmpty
        return lines
    }

    /// Splits on newlines, keeping where each piece starts (`base` is where `data` starts).
    private static func split(_ data: Data, at base: UInt64) -> [(offset: UInt64, data: Data)] {
        var at = base
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { piece in
            defer { at += UInt64(piece.count) + 1 }
            return (at, Data(piece))
        }
    }
}

extension TailReader {
    /// The complete lines in a stretch of the file around `offset`: `before` bytes ahead of it and
    /// `after` past it (for opening a long session at an older message).
    static func window(_ url: URL, around offset: UInt64, before: UInt64 = 200_000, after: UInt64 = 1_500_000) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let start = offset > before ? offset - before : 0
        // From the byte before `start`, so a line cut at the start can be told apart and dropped.
        try? handle.seek(toOffset: start > 0 ? start - 1 : 0)
        let data = (try? handle.read(upToCount: Int(before + after + 1))) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != UInt8(ascii: "\n") { _ = lines.popLast() }
        return lines.filter { !$0.isEmpty }
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

    /// Where in the file each item's line starts, so earlier history can be read on demand.
    private var itemOffsets: [UInt64] = []
    private var lineOffset: UInt64 = 0
    /// Where the loaded part of the file begins; there's earlier history before it.
    private(set) var historyStart: UInt64 = 0
    var hasEarlier: Bool { historyStart > 0 }
    /// Reading earlier history: it adds messages, but must not change the title or queue.
    private var historical = false

    static let maxItems = 600
    static let minFirstLoad = 150
    /// Raised as you load earlier history, so following new messages doesn't drop it again.
    private var limit = maxItems

    init(url: URL) { self.url = url }

    /// Reads just the part of the transcript around `offset` (it doesn't follow new lines).
    func loadWindow(around offset: UInt64) {
        for line in TailReader.window(url, around: offset) { ingest(line) }
    }

    /// Returns true if anything new was read.
    @discardableResult
    func refresh() -> Bool {
        let fresh = offset == nil
        let (lines, end) = TailReader.readLines(url, from: offset, maxBytes: 4_000_000)
        let changed = end != offset
        offset = end
        if fresh { historyStart = lines.first?.offset ?? 0 }
        for line in lines { lineOffset = line.offset; ingest(line.data) }
        // Long lines (images, big outputs) can leave only a screenful: open with a readable stretch.
        if fresh, items.count < Self.minFirstLoad { loadEarlier(minItems: Self.minFirstLoad - items.count) }
        if items.count > limit {
            // Cut at a line boundary, so loading earlier history resumes exactly there.
            var cut = items.count - limit
            while cut < items.count - 1, itemOffsets[cut] == itemOffsets[cut - 1] { cut += 1 }
            items.removeFirst(cut)
            itemOffsets.removeFirst(cut)
            historyStart = itemOffsets[0]
        }
        return changed && !lines.isEmpty
    }

    /// Reads the history before what's loaded, until there are `minItems` more messages or the
    /// start of the file. Returns false when there was nothing earlier.
    @discardableResult
    func loadEarlier(minItems: Int = 150, chunk: UInt64 = 2_000_000) -> Bool {
        guard hasEarlier else { return false }
        let (laterItems, laterOffsets) = (items, itemOffsets)
        var (earlier, earlierOffsets): ([TranscriptItem], [UInt64]) = ([], [])
        historical = true
        while historyStart > 0 && earlier.count < minItems {
            let lines = TailReader.lines(before: historyStart, in: url, chunk: chunk)
            items = []
            itemOffsets = []
            for line in lines { lineOffset = line.offset; ingest(line.data) }
            earlier = items + earlier
            earlierOffsets = itemOffsets + earlierOffsets
            historyStart = lines.first?.offset ?? 0
        }
        historical = false
        items = earlier + laterItems
        itemOffsets = earlierOffsets + laterOffsets
        limit = max(limit, items.count + Self.maxItems)
        return true
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
        case _ where historical && ["ai-title", "custom-title", "queue-operation"].contains(type):
            return
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
        case "system":
            // Things Claude Code shows in the terminal but writes as system records.
            ingestSystem(obj)
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
            itemOffsets.append(lineOffset)
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
                let input = block["input"] as? [String: Any] ?? [:]
                add(.tool(ToolCall(id: id, name: name, summary: Self.summarize(name: name, input: block["input"]),
                                   diff: EditDiff.lines(toolName: name, input: input))))
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                results[id] = ToolResult(text: Self.resultText(block["content"]),
                                         isError: block["is_error"] as? Bool == true)
            default:
                continue
            }
        }
    }

    private func ingestSystem(_ obj: [String: Any]) {
        guard obj["isSidechain"] as? Bool != true, let content = obj["content"] as? String else { return }
        let ts = (obj["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        let kind: TranscriptItem.Kind?
        switch obj["subtype"] as? String {
        case "local_command":
            // A slash command typed in the terminal (the command, then its output).
            kind = Self.userKind(content)
        case "away_summary":
            let text = content.replacingOccurrences(of: #"\s*\(disable recaps in /config\)\s*$"#, with: "", options: .regularExpression)
            kind = text.isEmpty ? nil : .recap(text)
        case "informational", "compact_boundary", "bridge_status":
            kind = .notice(Safety.stripANSI(content))
        default:
            kind = nil // turn timing and other bookkeeping
        }
        guard let kind else { return }
        counter += 1
        items.append(TranscriptItem(id: "\(uuid)-\(counter)", kind: kind, timestamp: ts))
        itemOffsets.append(lineOffset)
    }

    /// A user prompt is either a string or blocks of text and images.
    private func addUser(_ content: Any?, _ add: (TranscriptItem.Kind) -> Void) {
        if !historical, let text = content as? String, let i = queue.firstIndex(of: text) { queue.remove(at: i) }
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
                   let data = Data(base64Encoded: b64),
                   let thumb = Self.thumbnail(data, file: AttachmentStore.saveTranscriptImage(data, mediaType: source["media_type"] as? String)) {
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

    /// Downsampled once at parse time (max 640px), at 2x for Retina. `file` is the full image.
    static func thumbnail(_ data: Data, maxPixels: Int = 640, file: URL? = nil) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return TranscriptImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2), file: file)
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
            let out = Safety.stripANSI(between(text, "<local-command-stdout>", "</local-command-stdout>") ?? "")
            return out.isEmpty ? nil : .commandOutput(out)
        }
        if text.hasPrefix("<task-notification>") {
            let status = between(text, "<status>", "</status>") ?? "completed"
            let summary = between(text, "<summary>", "</summary>") ?? "Background task \(status)"
            return .taskEvent(summary, ok: status == "completed")
        }
        if text.hasPrefix("[Request interrupted") { return .notice("Interrupted") }
        // Messages pasted into the terminal (how older Deck versions sent them) are wrapped.
        if text.hasPrefix("<pasted_content"), let open = text.firstIndex(of: ">") {
            var inner = text[text.index(after: open)...]
            if let close = inner.range(of: "</pasted_content", options: .backwards) { inner = inner[..<close.lowerBound] }
            return userKind(String(inner))
        }
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

/// A thumbnail of an image in a message, and where the full image is saved (to view it).
final class TranscriptImage: NSImage {
    // Set once, right after creation.
    nonisolated(unsafe) private(set) var file: URL?

    convenience init(cgImage: CGImage, size: NSSize, file: URL?) {
        self.init(size: size)
        addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        self.file = file
    }
}
