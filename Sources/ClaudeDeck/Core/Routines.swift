import Foundation

/// When a routine runs: at a time of day (every day or on chosen weekdays), or every few hours.
struct RoutineSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case daily, interval }
    var kind: Kind = .daily
    var hour = 9
    var minute = 0
    /// The days it runs, 1 = Sunday … 7 = Saturday (as Calendar counts); empty means every day.
    var weekdays: [Int] = []
    var everyHours = 2

    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var time: String { String(format: "%d:%02d", hour, minute) }

    /// "Every day at 9:00", "Weekdays at 9:00", "Mon, Thu at 18:30", "Every 2 hours".
    var summary: String {
        if kind == .interval { return everyHours == 1 ? "Every hour" : "Every \(everyHours) hours" }
        let days = Set(weekdays)
        let when = switch days {
        case [], Set(1...7): "Every day"
        case Set(2...6): "Weekdays"
        case [1, 7]: "Weekends"
        default: days.sorted().map { Self.weekdayNames[$0 - 1] }.joined(separator: ", ")
        }
        return "\(when) at \(time)"
    }

    /// The keys launchd schedules the job with. launchd counts weekdays from 0 = Sunday.
    var launchd: [String: Any] {
        if kind == .interval { return ["StartInterval": max(1, everyHours) * 3600] }
        let days = weekdays.isEmpty ? [nil] : weekdays.sorted().map { Optional($0) }
        return ["StartCalendarInterval": days.map { day -> [String: Int] in
            var entry = ["Hour": hour, "Minute": minute]
            if let day { entry["Weekday"] = day - 1 }
            return entry
        }]
    }

    private func runs(on day: Date, calendar: Calendar) -> Bool {
        weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: day))
    }

    private func slot(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// The next time it runs after `date`. An interval routine runs `everyHours` after its last run
    /// (or from `date` if it hasn't run).
    func next(after date: Date, lastRun: Date? = nil, calendar: Calendar = .current) -> Date {
        if kind == .interval {
            let step = TimeInterval(max(1, everyHours) * 3600)
            var at = (lastRun ?? date).addingTimeInterval(step)
            while at <= date { at += step }
            return at
        }
        for offset in 0...7 {
            let day = calendar.date(byAdding: .day, value: offset, to: date)!
            let at = slot(on: day, calendar: calendar)
            if at > date, runs(on: day, calendar: calendar) { return at }
        }
        return date.addingTimeInterval(7 * 86400)  // no weekday matches: never reached with valid days
    }

    /// The last time it was due at or before `date` (daily routines only).
    func previous(before date: Date, calendar: Calendar = .current) -> Date? {
        guard kind == .daily else { return nil }
        for offset in 0...7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: date)!
            let at = slot(on: day, calendar: calendar)
            if at <= date, runs(on: day, calendar: calendar) { return at }
        }
        return nil
    }
}

/// A prompt Claude runs on a schedule in a folder, headless, with fixed access.
struct Routine: Codable, Identifiable, Equatable {
    enum Access: String, Codable, CaseIterable {
        /// Reads, searches, and git / gh commands that only look.
        case readOnly
        /// Also edits and writes files.
        case canEdit
        /// Also runs any command; your policies are the guard.
        case runCommands
    }

    var id = "r-" + UUID().uuidString.prefix(8).lowercased()
    var name = ""
    var folder = ""
    var prompt = ""
    var schedule = RoutineSchedule()
    var access = Access.readOnly
    /// Empty: Claude Code's default model.
    var model = ""
    /// Most a run may spend, in US dollars; nil for no cap.
    var budget: Double? = nil
    var timeoutMinutes = 30
    var enabled = true
    var created = Date()
}

/// One run of a routine, written by the helper as it starts and when it finishes.
struct RoutineRun: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case running, succeeded, failed, timedOut }

    var id: String
    var routine: String
    var started: Date
    var finished: Date?
    var status = Status.running
    /// The headless session, so its whole conversation can be opened.
    var sessionId: String?
    var cost: Double?
    var turns: Int?
    /// Claude's final message, or what went wrong.
    var result: String?
    /// Tool calls refused because the routine's access didn't allow them.
    var denied = 0
    /// The helper running it; a "running" run whose helper is gone was cut off.
    var pid: Int32?

    /// Running, but its helper has gone (the Mac slept through it, or it was killed).
    func isCutOff(alive: (Int32) -> Bool) -> Bool {
        status == .running && !(pid.map(alive) ?? false)
    }
}

enum Routines {
    /// Tests point these at temporary folders.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck/routines")
    static var runsDir: URL { dir.appendingPathComponent("runs") }
    nonisolated(unsafe) static var agentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    nonisolated(unsafe) static var launchctl = "/bin/launchctl"
    /// The helper's file name inside Deck.app.
    static let helperName = "deck-routine"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    // MARK: Routines and runs on disk

    static func load() -> [Routine] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Routine.self, from: $0) } }
            .sorted { $0.created < $1.created }
    }

    static func routine(_ id: String) -> Routine? { load().first { $0.id == id } }

    static func save(_ routine: Routine) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(routine).write(to: dir.appendingPathComponent("\(routine.id).json"), options: .atomic)
    }

    /// Removes the routine and its run history.
    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        for run in runs(of: id) { try? FileManager.default.removeItem(at: url(of: run)) }
    }

    static func url(of run: RoutineRun) -> URL { runsDir.appendingPathComponent("\(run.routine)__\(run.id).json") }

    static func write(_ run: RoutineRun) {
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try? encoder.encode(run).write(to: url(of: run), options: .atomic)
    }

    /// Every run, newest first (of one routine when `id` is given), keeping the newest `keep` per routine.
    static func runs(of id: String? = nil) -> [RoutineRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && (id == nil || $0.lastPathComponent.hasPrefix("\(id!)__")) }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(RoutineRun.self, from: $0) } }
            .sorted { $0.started > $1.started }
    }

    /// Keeps the newest `keep` runs of a routine.
    static func prune(_ id: String, keep: Int = 50) {
        for old in runs(of: id).dropFirst(keep) { try? FileManager.default.removeItem(at: url(of: old)) }
    }

    // MARK: The headless run

    /// What each access level lets Claude do without asking (nothing else is allowed: the run uses
    /// `dontAsk`, which refuses anything not listed). Deck's policies still check every call.
    static func allowedTools(_ access: Routine.Access) -> [String] {
        let looking = ["git status", "git log", "git diff", "git show", "git branch", "git fetch",
                       "gh pr list", "gh pr view", "gh pr checks", "gh pr diff", "gh run list", "gh run view",
                       "gh issue list", "gh issue view", "gh api", "ls", "cat", "head", "tail", "wc", "find", "grep", "rg"]
        let read = ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite"] + looking.map { "Bash(\($0):*)" }
        let edit = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
        return switch access {
        case .readOnly: read
        case .canEdit: read + edit
        case .runCommands: ["Bash"] + read.filter { !$0.hasPrefix("Bash(") } + edit
        }
    }

    /// The `claude` arguments for one run. Each value is its own argument (never through a shell).
    /// The session id is chosen up front, so Deck can follow the conversation while it runs.
    static func arguments(for routine: Routine, sessionId: String? = nil) -> [String] {
        var args = ["-p", routine.prompt, "--output-format", "json", "--permission-mode", "dontAsk",
                    "--name", "Routine: \(routine.name)"]
        if let sessionId { args += ["--session-id", sessionId] }
        if let budget = routine.budget { args += ["--max-budget-usd", String(format: "%.2f", budget)] }
        if !routine.model.isEmpty { args += ["--model", routine.model] }
        // Last: the tool list takes every argument after it.
        return args + ["--allowedTools"] + allowedTools(routine.access)
    }

    /// Reads `claude -p --output-format json`'s summary into the run.
    static func finish(_ run: inout RoutineRun, output: Data, exitStatus: Int32, stderr: String, timedOut: Bool, at: Date = Date()) {
        run.finished = at
        let summary = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        run.sessionId = summary?["session_id"] as? String ?? run.sessionId
        run.cost = summary?["total_cost_usd"] as? Double
        run.turns = summary?["num_turns"] as? Int
        run.denied = (summary?["permission_denials"] as? [Any])?.count ?? 0
        let result = (summary?["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if timedOut {
            run.status = .timedOut
            run.result = result ?? "Stopped after its time limit."
        } else if summary == nil || summary?["is_error"] as? Bool == true || exitStatus != 0 {
            run.status = .failed
            let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            run.result = result ?? (said.isEmpty ? "Claude exited with status \(exitStatus)." : String(said.suffix(2000)))
        } else {
            run.status = .succeeded
            run.result = result
        }
    }

    /// Runs `path` with `args` in `folder`, stopping it after `timeout`. Returns what it printed.
    static func execute(_ path: String, _ args: [String], in folder: String, timeout: TimeInterval)
        -> (output: Data, stderr: String, status: Int32, timedOut: Bool)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (Data(), error.localizedDescription, -1, false) }
        let stopped = Flag()
        let killer = DispatchWorkItem {
            stopped.set()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Both pipes are read at once, so neither can fill up and stall the child.
        let errData = Collected()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            errData.set(err.fileHandleForReading.readDataToEndOfFile())
            reading.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        reading.wait()
        killer.cancel()
        return (data, String(decoding: errData.value, as: UTF8.self), p.terminationStatus, stopped.isSet)
    }

    /// Commands Claude runs (git, gh, npm…) live outside launchd's minimal PATH.
    static var searchPath: String {
        let home = NSHomeDirectory()
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// The helper's job: run the routine once, unless a run of it is still going. Returns the
    /// finished run, or nil when it was skipped (no such routine, no folder, already running).
    @discardableResult
    static func run(_ id: String, claude: String? = ClaudeCLI.locate(), now: Date = Date(), pid: Int32 = getpid()) -> RoutineRun? {
        guard let routine = routine(id) else { return nil }
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        // One run at a time: the lock is held until this process exits.
        let lock = open(runsDir.appendingPathComponent("\(id).lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { close(lock) }

        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        var run = RoutineRun(id: stamp.replacingOccurrences(of: ":", with: ""), routine: id, started: now, pid: pid)
        var isDir: ObjCBool = false
        guard let claude else {
            finish(&run, output: Data(), exitStatus: -1, stderr: "Couldn't find the claude command.", timedOut: false)
            write(run)
            return run
        }
        guard FileManager.default.fileExists(atPath: routine.folder, isDirectory: &isDir), isDir.boolValue else {
            finish(&run, output: Data(), exitStatus: -1, stderr: "The folder \(routine.folder) doesn't exist.", timedOut: false)
            write(run)
            return run
        }
        run.sessionId = UUID().uuidString.lowercased()
        write(run)
        let r = execute(claude, arguments(for: routine, sessionId: run.sessionId), in: routine.folder,
                        timeout: TimeInterval(routine.timeoutMinutes * 60))
        finish(&run, output: r.output, exitStatus: r.status, stderr: r.stderr, timedOut: r.timedOut)
        write(run)
        prune(id)
        return run
    }

    /// A daily routine missed while the Mac was off (launchd runs ones missed while asleep itself):
    /// due since its last run, within the last 12 hours.
    static func missed(_ routine: Routine, lastRun: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard routine.enabled, let due = routine.schedule.previous(before: now, calendar: calendar),
              now.timeIntervalSince(due) < 12 * 3600 else { return false }
        return due > max(lastRun ?? .distantPast, routine.created)
    }

    // MARK: launchd

    static func label(_ id: String) -> String { "com.devenbhooshan.claudedeck.routine.\(id)" }
    static func plistURL(_ id: String) -> URL { agentsDir.appendingPathComponent("\(label(id)).plist") }

    /// The launchd job: the helper runs the routine on its schedule, whether Deck is open or not.
    static func plist(for routine: Routine, helper: String) -> Data {
        var job: [String: Any] = [
            "Label": label(routine.id),
            "ProgramArguments": [helper, "run", routine.id],
            "EnvironmentVariables": ["PATH": searchPath],
            "StandardErrorPath": runsDir.appendingPathComponent("\(routine.id).log").path,
            "ProcessType": "Background",
        ]
        for (key, value) in routine.schedule.launchd { job[key] = value }
        return try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    private static var domain: String { "gui/\(getuid())" }

    /// Schedules the routine (or unschedules it when it's paused).
    static func install(_ routine: Routine, helper: String) throws {
        uninstall(routine.id)
        guard routine.enabled else { return }
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try plist(for: routine, helper: helper).write(to: plistURL(routine.id), options: .atomic)
        let r = execute(launchctl, ["bootstrap", domain, plistURL(routine.id).path], in: "/", timeout: 20)
        if r.status != 0 {
            throw NSError(domain: "ClaudeDeck", code: Int(r.status), userInfo: [
                NSLocalizedDescriptionKey: "launchctl couldn't schedule it: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    static func uninstall(_ id: String) {
        _ = execute(launchctl, ["bootout", "\(domain)/\(label(id))"], in: "/", timeout: 20)
        try? FileManager.default.removeItem(at: plistURL(id))
    }
}

/// A thread-safe "it happened" flag.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Data read on another thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.withLock { data = d } }
    var value: Data { lock.withLock { data } }
}
