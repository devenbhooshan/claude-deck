import AppKit
import Foundation

/// Drives Ghostty (1.3+) over AppleScript: find the terminal hosting a session,
/// type into it, press keys, and bring it to the front.
///
/// Safety rules, enforced here so every caller gets them:
/// - Before any action, the same script re-checks that the terminal is still in the session's
///   folder and still shows a Claude title; otherwise nothing is typed (`mismatch`).
/// - Messages are only typed when the session isn't showing a dialog, and keys only answer
///   the dialog you were shown (`PromptGuard`, from a fresh read of the session's record).
/// - Only "terminal not found / moved" is retried, never a half-finished action.
enum Ghostty {
    enum Failure: LocalizedError {
        case script(String)
        case notFound
        case promptOpen
        case promptChanged
        case invalidSession

        var errorDescription: String? {
            switch self {
            case .script(let msg): msg
            case .notFound: "Couldn't find this session's Ghostty terminal. Is it running in Ghostty?"
            case .promptOpen: "Claude is showing a prompt. Answer it first, then send your message."
            case .promptChanged: "That prompt was already answered or has changed. Nothing was sent."
            case .invalidSession: "This doesn't look like a Claude Code session id, so it wasn't resumed."
            }
        }
    }

    private final class IdCache: @unchecked Sendable {
        private var ids: [String: String] = [:]
        private let lock = NSLock()

        subscript(key: String) -> String? {
            get { lock.withLock { ids[key] } }
            set { lock.withLock { ids[key] = newValue } }
        }
    }

    private static let cache = IdCache()

    private static func cacheKey(_ s: Session) -> String { "\(s.sessionId):\(s.pid ?? 0)" }

    /// Every character Claude Code starts its title with, for the in-script check.
    private static let marks: String = String(TerminalMatch.claudeMarks)
        + String(String.UnicodeScalarView((0x2800...0x28FF).compactMap(Unicode.Scalar.init)))

    // MARK: - Actions

    /// Resolves and caches the session's terminal ahead of time so the first action is instant.
    static func prewarm(_ session: Session) async {
        _ = try? await terminalId(for: session)
    }

    /// Types a message (as typed input, not a paste, so Claude treats it as yours) and presses Return.
    /// Images are pasted as file paths first, which Claude Code turns into image attachments.
    static func send(text: String, images: [URL] = [], to session: Session) async throws {
        guard PromptGuard.canType(session.pid.flatMap(SessionLoader.record(pid:))) else { throw Failure.promptOpen }
        let typed = text.isEmpty ? "" : Safety.typedTextAction(text)
        try await act(on: session, """
              repeat with i from 6 to count of argv
                input text (item i of argv) to t
                -- Give Claude Code a moment to load each image before the next paste.
                delay 0.3
              end repeat
              if (item 4 of argv) is not "" then
                if (count of argv) > 5 then input text " " to t
                perform action (item 4 of argv) on t
              end if
              -- Return right after typing counts as part of the typing burst (a new line); pause first.
              delay 0.25
              send key "enter" to t
            """, args: [typed, ""] + images.map(\.path))
    }

    /// Presses a key in the session's permission dialog, only if it's still the one you saw.
    static func press(key: String, on session: Session, expectedSince: Double?) async throws {
        let record = session.pid.flatMap(SessionLoader.record(pid:))
        guard PromptGuard.canAnswer(record, expectedSince: expectedSince) else { throw Failure.promptChanged }
        try await act(on: session, """
              send key (item 4 of argv) to t
            """, args: [key, ""])
    }

    static func focus(_ session: Session) async throws {
        try await act(on: session, """
              focus t
              activate
            """, args: ["", ""])
    }

    /// Opens a new Ghostty window that resumes an ended session.
    static func resume(_ session: Session) async throws {
        // The id is typed into a shell, so it must be exactly a session id.
        guard Safety.isSessionId(session.sessionId) else { throw Failure.invalidSession }
        try await openWindow(in: session.cwd, typing: "claude --resume \(session.sessionId)")
    }

    /// Opens a new Ghostty window in `folder` and starts Claude Code there.
    static func newSession(in folder: String) async throws {
        try await openWindow(in: folder, typing: "claude")
    }

    /// The folder is passed as Ghostty's working directory (never through the shell); `command`
    /// is a fixed string we built, typed into the new shell.
    private static func openWindow(in folder: String, typing command: String) async throws {
        _ = try await run("""
            on run argv
              tell application "Ghostty"
                set cfg to new surface configuration
                set initial working directory of cfg to (item 1 of argv)
                set initial input of cfg to ((item 2 of argv) & linefeed)
                new window with configuration cfg
                activate
              end tell
            end run
            """, args: [folder, command])
    }

    // MARK: - Terminal lookup

    /// Runs `body` (AppleScript using `t`) on the session's terminal after re-checking, in the same
    /// script, that it's still in the session's folder with a Claude title. argv: 1 id, 2 folder,
    /// 3 marks, then `args`. A stale cached id is re-resolved once; other failures aren't retried.
    private static func act(on session: Session, _ body: String, args: [String]) async throws {
        let script = """
            on run argv
              tell application "Ghostty"
                set t to terminal id (item 1 of argv)
                set n to name of t
                set d to working directory of t
              end tell
              if d is not (item 2 of argv) then return "mismatch"
              if n is "" then return "mismatch"
              if (character 1 of n) is not in (item 3 of argv) then return "mismatch"
              tell application "Ghostty"
            \(body)
              end tell
              return "ok"
            end run
            """
        let key = cacheKey(session)
        for attempt in 0..<2 {
            let id = try await terminalId(for: session)
            let result: String
            do {
                result = try await run(script, args: [id, session.cwd, marks] + args)
            } catch Failure.script(let msg) where msg.contains("-1728") || msg.contains("terminal id") {
                result = "mismatch" // The cached terminal is gone.
            }
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" { return }
            cache[key] = nil
            if attempt == 1 { throw Failure.notFound }
        }
    }

    private static func terminalId(for session: Session) async throws -> String {
        let key = cacheKey(session)
        if let id = cache[key] { return id }
        let id = try await findTerminal(for: session).id
        cache[key] = id
        return id
    }

    static func terminals() async throws -> [GhosttyTerminal] {
        // Fetch each property for all terminals in one Apple event, then join locally with
        // separators (US/RS) that can't appear in titles.
        let out = try await run("""
            on run argv
              set fs to character id 31
              set rs to character id 30
              tell application "Ghostty"
                set ids to id of terminals
                set names to name of terminals
                set dirs to working directory of terminals
              end tell
              set out to ""
              repeat with i from 1 to count of ids
                set d to ""
                try
                  set d to item i of dirs as text
                end try
                set out to out & (item i of ids) & fs & (item i of names) & fs & d & rs
              end repeat
              return out
            end run
            """)
        return TerminalMatch.parse(out)
    }

    static func findTerminal(for session: Session) async throws -> GhosttyTerminal {
        guard let t = TerminalMatch.find(for: session, in: try await terminals()) else { throw Failure.notFound }
        return t
    }

    private static func run(_ script: String, args: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script] + args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if p.terminationStatus != 0 {
                        let msg = String(data: errData, encoding: .utf8) ?? "osascript failed"
                        cont.resume(throwing: Failure.script(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
