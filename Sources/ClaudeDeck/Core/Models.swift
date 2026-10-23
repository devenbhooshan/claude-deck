import AppKit
import Foundation

/// A record from ~/.claude/sessions/<pid>.json, written by every running Claude Code process.
struct SessionRecord: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double?
    let kind: String?
    /// "cli" for a terminal session; "sdk-cli" for headless runs (`claude -p`, the Agent SDK).
    var entrypoint: String? = nil
    let name: String?
    let status: String?
    let waitingFor: String?
    let updatedAt: Double?
    let statusUpdatedAt: Double?
    let detail: String?
    /// Set while the session is connected with Remote Control.
    var bridgeSessionId: String? = nil
}

extension SessionRecord {
    /// Headless runs (Deck's own `claude -p /usage` checks, scripts, the Agent SDK) have no
    /// terminal to type into, so they aren't shown as sessions.
    var isHeadless: Bool { entrypoint == "sdk-cli" }
}

enum SessionStatus: String {
    /// `background`: Claude is at its prompt but a background task it started is still running
    /// (one that isn't a server; a session running only servers counts as idle).
    case waiting, busy, background, idle, ended

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .busy: "Working"
        case .background: "Background task"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    var sortRank: Int {
        switch self {
        case .waiting: 0
        case .busy: 1
        case .background: 2
        case .idle: 3
        case .ended: 4
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
    /// When the session started; running sessions keep this order so they never jump around.
    var startedAt: Date? = nil
    /// Commands Claude started in the background that are still running.
    var background: [BackgroundTask] = []
    /// When Claude wrote each reply since your last message, oldest first.
    var replies: [Date] = []
    /// The claude.ai session it's connected to with Remote Control, if it is.
    var remoteId: String? = nil

    var isLive: Bool { pid != nil }
    /// Where to open it on claude.ai or the Claude app; only a well-formed id becomes a link.
    var remoteURL: URL? {
        guard let remoteId, remoteId.range(of: #"^session_[A-Za-z0-9]+$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: "https://claude.ai/code/\(remoteId)")
    }
    /// Only servers and watchers run in the background: shown as idle, with the server noted.
    var onlyServers: Bool { !background.isEmpty && background.allSatisfy(\.isServer) }

    /// `statusSince` as Claude Code writes it (milliseconds), to identify the prompt being answered.
    var statusStamp: Double? { statusSince.map { $0.timeIntervalSince1970 * 1000 } }

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
        /// Output of a slash command that ran in the terminal (e.g. /cost, /context).
        case commandOutput(String)
        /// Claude Code's "※ recap" of where a session stands, shown when you come back to it.
        case recap(String)
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
    /// For file edits: the change, as a compact line diff.
    var diff: [DiffLine]? = nil
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
    /// When Claude wrote each reply since your last message (for unread counts).
    var replies: [Date] = []
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
