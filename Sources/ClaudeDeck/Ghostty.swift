import AppKit
import Foundation

/// Drives Ghostty (1.3+) over AppleScript: find the terminal hosting a session,
/// type into it, press keys, and bring it to the front.
///
/// Each session's terminal id is cached, so actions are a single direct
/// `terminal id "…"` call (~0.1s) instead of a scan of every terminal.
enum Ghostty {
    enum Failure: LocalizedError {
        case script(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .script(let msg): msg
            case .notFound: "Couldn't find this session's Ghostty terminal. Is it running in Ghostty?"
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

    // MARK: - Actions

    /// Resolves and caches the session's terminal ahead of time so the first action is instant.
    static func prewarm(_ session: Session) async {
        _ = try? await terminalId(for: session)
    }

    /// Images are sent as pasted file paths, which Claude Code turns into image attachments
    /// (the same thing that happens when you drag an image into the terminal).
    static func send(text: String, images: [URL] = [], to session: Session) async throws {
        try await withTerminal(session) { id in
            _ = try await run("""
                on run argv
                  set n to count of argv
                  tell application "Ghostty"
                    set t to terminal id (item 1 of argv)
                    repeat with i from 3 to n
                      input text (item i of argv) to t
                      -- Give Claude Code a moment to load each image before the next paste.
                      delay 0.3
                    end repeat
                    if (item 2 of argv) is not "" then
                      if n > 2 then input text " " to t
                      input text (item 2 of argv) to t
                    end if
                    send key "enter" to t
                  end tell
                end run
                """, args: [id, text] + images.map(\.path))
        }
    }

    static func press(key: String, on session: Session) async throws {
        try await withTerminal(session) { id in
            _ = try await run("""
                on run argv
                  tell application "Ghostty" to send key (item 2 of argv) to terminal id (item 1 of argv)
                end run
                """, args: [id, key])
        }
    }

    static func focus(_ session: Session) async throws {
        try await withTerminal(session) { id in
            _ = try await run("""
                on run argv
                  tell application "Ghostty"
                    focus terminal id (item 1 of argv)
                    activate
                  end tell
                end run
                """, args: [id])
        }
    }

    /// Opens a new Ghostty window that resumes an ended session.
    static func resume(_ session: Session) async throws {
        _ = try await run("""
            on run argv
              tell application "Ghostty"
                set cfg to new surface configuration
                set initial working directory of cfg to (item 1 of argv)
                set initial input of cfg to ("claude --resume " & (item 2 of argv) & linefeed)
                new window with configuration cfg
                activate
              end tell
            end run
            """, args: [session.cwd, session.sessionId])
    }

    // MARK: - Terminal lookup

    /// Runs `body` with the cached terminal id; if that terminal is gone, re-resolves once and retries.
    private static func withTerminal(_ session: Session, _ body: (String) async throws -> Void) async throws {
        let key = cacheKey(session)
        if let cached = cache[key] {
            do {
                try await body(cached)
                return
            } catch {
                cache[key] = nil
            }
        }
        try await body(try await terminalId(for: session))
    }

    private static func terminalId(for session: Session) async throws -> String {
        let key = cacheKey(session)
        if let id = cache[key] { return id }
        let id = try await findTerminal(for: session).id
        cache[key] = id
        return id
    }

    static func terminals() async throws -> [GhosttyTerminal] {
        // Fetch each property for all terminals in one Apple event, then join locally.
        let out = try await run("""
            on run argv
              set sep to character id 9
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
                set out to out & (item i of ids) & sep & (item i of names) & sep & d & linefeed
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
