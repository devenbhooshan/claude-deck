import AppKit
import Foundation

/// A record from ~/.claude/sessions/<pid>.json, written by every running Claude Code process.
struct SessionRecord: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double?
    let kind: String?
    let name: String?
    let status: String?
    let waitingFor: String?
    let updatedAt: Double?
    let statusUpdatedAt: Double?
    let detail: String?
}

enum SessionStatus: String {
    case waiting, busy, idle, ended

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .busy: "Working"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    var sortRank: Int {
        switch self {
        case .waiting: 0
        case .busy: 1
        case .idle: 2
        case .ended: 3
        }
    }
}

struct Session: Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    var pid: Int32?
    var cwd: String
    var name: String?
    var title: String?
    var status: SessionStatus
    var waitingFor: String?
    var updatedAt: Date
    var transcriptURL: URL?
    /// When the current status began (e.g. when Claude started working).
    var statusSince: Date? = nil
    /// What a permission prompt is asking about, when known.
    var pendingTool: ToolCall? = nil

    var isLive: Bool { pid != nil }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        return projectName
    }

    var projectName: String { (cwd as NSString).lastPathComponent }
}

/// One rendered row of a transcript.
struct TranscriptItem: Identifiable {
    enum Kind {
        /// Images are pre-decoded thumbnails, so views never decode on the main thread.
        case user(String, images: [NSImage])
        case command(String)
        case assistant(String)
        case tool(ToolCall)
        case notice(String)
        /// A background task finished (from a <task-notification>).
        case taskEvent(String, ok: Bool)
    }

    let id: String
    let kind: Kind
    let timestamp: Date?
}

struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
}

struct ToolResult {
    let text: String
    let isError: Bool
}

/// Consecutive tool calls are grouped into one card in the UI.
enum TranscriptBlock: Identifiable {
    case item(TranscriptItem)
    case tools([ToolCall])

    var id: String {
        switch self {
        case .item(let i): i.id
        case .tools(let calls): "tools-" + (calls.first?.id ?? "")
        }
    }

    static func group(_ items: [TranscriptItem]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var run: [ToolCall] = []
        for item in items {
            if case .tool(let call) = item.kind {
                run.append(call)
                continue
            }
            if !run.isEmpty { blocks.append(.tools(run)); run = [] }
            blocks.append(.item(item))
        }
        if !run.isEmpty { blocks.append(.tools(run)) }
        return blocks
    }
}

/// Cached transcript title, keyed by transcript path.
struct TitleInfo: Equatable {
    let mtime: Date
    let title: String?
    let isCustom: Bool
}

/// A message just sent from Deck, shown until the transcript catches up.
struct OutgoingMessage: Identifiable {
    let id: UUID
    let text: String
    let images: [NSImage]
    var sentAt: Date
    var delivered = false

    init(text: String, images: [NSImage], sentAt: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.images = images
        self.sentAt = sentAt
    }
}
