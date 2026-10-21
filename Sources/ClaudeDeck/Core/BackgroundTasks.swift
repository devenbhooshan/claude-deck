import Foundation

/// A command Claude started in the background (Bash with run_in_background) that's still running.
struct BackgroundTask: Equatable, Identifiable {
    /// The shell Claude Code started it in; it leads the task's process group.
    let pid: Int32
    /// The Claude Code process that started it.
    let parent: Int32
    /// What Claude ran, tidied for display: "bin/dev".
    let command: String
    let started: Date
    /// A dev server or watcher, meant to keep running ("bin/dev", "npm run dev", "rails s").
    let isServer: Bool

    var id: Int32 { pid }
}

/// Finds background tasks from the process list: Claude Code runs each Bash command as
/// `zsh -c "source <shell snapshot> … && eval '<command>' < /dev/null && pwd -P >| <file>"`,
/// as a child of the Claude process, in its own process group.
enum BackgroundTasks {
    /// Commands that are servers or watchers, meant to run until stopped.
    private static let server = try! NSRegularExpression(pattern: #"""
        (?ix)
        (?:^|[\s/;&|(])(?:
            bin/dev | bin/rails\s+s(?:erver)?\b | rails\s+s(?:erver)?\b | foreman\s+start | overmind\s+start
          | (?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:dev|start|serve|watch)\b | npx\s+(?:next|vite|nodemon)\b
          | next\s+dev | vite\b | nodemon\b | webpack\s+(?:serve|--watch) | tsc\s+.*--watch
          | (?:uvicorn|gunicorn|hypercorn|daphne)\b | flask\s+run | manage\.py\s+runserver | python3?\s+-m\s+http\.server
          | (?:docker[\s-]compose|docker\s+compose)\s+up | hugo\s+server | jekyll\s+serve | mkdocs\s+serve
          | php\s+artisan\s+serve | mix\s+phx\.server | cargo\s+watch | air\b | go\s+run\b.*server
          | tail\s+-f\s+(?!/dev/null)
        )
        """#)

    static func isServer(_ command: String) -> Bool {
        server.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    /// The command inside a Claude Code shell's command line, or nil if it isn't one.
    static func command(fromShell line: String) -> String? {
        guard line.contains("/shell-snapshots/"), let start = line.range(of: "&& eval '"),
              let end = line.range(of: "' < /dev/null", options: .backwards), start.upperBound <= end.lowerBound
        else { return nil }
        return String(line[start.upperBound..<end.lowerBound]).replacingOccurrences(of: #"'\''"#, with: "'")
    }

    /// The part worth showing: without `export X=…;` set-up, a `tail -f /dev/null |` feeder,
    /// or redirections to a log file.
    static func tidy(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules: [(String, String)] = [
            (#"^(?:\s*export\s+[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s;]*)\s*;\s*)+"#, ""),
            (#"^\s*tail\s+-f\s+/dev/null\s*\|\s*"#, ""),
            (#"\s*(?:\d?>>?|&>)\s*\S+(?:\s+2>&1)?\s*$"#, ""),
            (#"\s+2>&1\s*$"#, ""),
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s.isEmpty ? command : s
    }

    /// `ps` elapsed time ("[[dd-]hh:]mm:ss") in seconds.
    static func seconds(fromElapsed text: String) -> TimeInterval? {
        let dayParts = text.split(separator: "-", maxSplits: 1)
        let days = dayParts.count == 2 ? Double(dayParts[0]) : 0
        let clock = (dayParts.last ?? "").split(separator: ":").map { Double($0) }
        guard let days, !clock.isEmpty, clock.count <= 3, !clock.contains(nil) else { return nil }
        let units: [Double] = [1, 60, 3600]
        let total = clock.reversed().enumerated().reduce(0.0) { $0 + $1.element! * units[$1.offset] }
        return days * 86400 + total
    }

    /// Background tasks by Claude process, from `ps -axww -o pid=,ppid=,pgid=,etime=,command=`.
    static func parse(_ ps: String, now: Date = Date()) -> [Int32: [BackgroundTask]] {
        var tasks: [Int32: [BackgroundTask]] = [:]
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let pgid = Int32(fields[2]),
                  pid == pgid, let age = seconds(fromElapsed: String(fields[3])),
                  let raw = command(fromShell: String(fields[4])) else { continue }
            let shown = tidy(raw)
            tasks[ppid, default: []].append(BackgroundTask(pid: pid, parent: ppid, command: shown,
                                                           started: now.addingTimeInterval(-age), isServer: isServer(raw)))
        }
        return tasks.mapValues { $0.sorted { $0.started < $1.started } }
    }

    /// The process list right now.
    static func snapshot() -> [Int32: [BackgroundTask]] {
        parse(run(["-axww", "-o", "pid=,ppid=,pgid=,etime=,command="]))
    }

    /// Stops a task: its whole process group gets SIGTERM, then SIGKILL if it's still there after
    /// `grace`. Only if it's still the same task: same shell, same Claude process, leading its group.
    @discardableResult
    static func stop(_ task: BackgroundTask, grace: TimeInterval = 3) -> Bool {
        guard snapshot()[task.parent]?.contains(where: { $0.pid == task.pid }) == true else { return false }
        kill(-task.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while kill(-task.pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(-task.pid, 0) == 0 { kill(-task.pid, SIGKILL) }
        return true
    }

    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
