import AppKit
import Observation

/// A routine with finished runs you haven't looked at.
struct UnreadRoutine: Identifiable {
    let routine: Routine
    /// The newest of them.
    let run: RoutineRun
    let count: Int
    var id: String { routine.id }
}

/// Your routines and their runs, kept current from the files the helper writes. Owned by the
/// session store, which shows unread runs in the Dock badge.
@MainActor @Observable
final class RoutineStore {
    private(set) var routines: [Routine] = []
    /// Every run, newest first.
    private(set) var runs: [RoutineRun] = []
    var lastError: String?
    /// Runs that finished after this were not seen yet (everything before Deck had routines is seen).
    private(set) var seenUpTo: Date = {
        if let t = UserDefaults.standard.object(forKey: "routineRunsSeen") as? Double { return Date(timeIntervalSince1970: t) }
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "routineRunsSeen")
        return now
    }()
    /// When you last looked at each routine's runs, by routine id.
    private var seen: [String: Date] = (UserDefaults.standard.dictionary(forKey: "routineSeen") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) }
    /// Routines still showing the popup, by id.
    private var announced: Set<String> = []
    /// Called when unread runs change (for the Dock badge and the popup).
    var onChange: (() -> Void)?
    /// Whether you're looking at a routine right now, so its runs aren't announced.
    var isOpen: (String) -> Bool = { _ in false }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var routinesWatcher: FileWatcher?
    /// What each run's status was last time, to notify once when one finishes.
    @ObservationIgnored private var known: [String: RoutineRun.Status]?

    /// The runner bundled next to Deck's own executable.
    var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Routines.helperName)").path }

    func start() {
        try? FileManager.default.createDirectory(at: Routines.runsDir, withIntermediateDirectories: true)
        reload()
        // Runs are written as files: a new or finished run changes the folder.
        watcher = FileWatcher(url: Routines.runsDir, events: [.write]) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Routines change here too when `deck-routine` edits them.
        routinesWatcher = FileWatcher(url: Routines.dir, events: [.write]) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        catchUp()
    }

    func reload() {
        routines = Routines.load()
        runs = Routines.runs()
        let since = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "routinesLooked"))
        let done = Routines.justFinished(runs, known: known, since: since).filter { isUnread($0) && !isOpen($0.routine) }
        if !done.isEmpty {
            announced.formUnion(done.map(\.routine))
            NSSound(named: "Glass")?.play()
            NSApp?.requestUserAttention(.informationalRequest)
        }
        known = Dictionary(runs.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "routinesLooked")
        onChange?()
    }

    func runs(of id: String) -> [RoutineRun] { runs.filter { $0.routine == id } }
    func routine(_ id: String) -> Routine? { routines.first { $0.id == id } }

    /// Finished runs you haven't looked at.
    var unread: Int { unreadRoutines.reduce(0) { $0 + $1.count } }
    func unread(of id: String) -> Int { runs(of: id).filter(isUnread).count }
    func isUnread(_ run: RoutineRun) -> Bool {
        (run.finished ?? .distantPast) > max(seenUpTo, seen[run.routine] ?? .distantPast)
    }

    /// Newest first, for the floating dock.
    var unreadRoutines: [UnreadRoutine] {
        routines.compactMap { r in
            let new = runs(of: r.id).filter(isUnread)
            return new.first.map { UnreadRoutine(routine: r, run: $0, count: new.count) }
        }
        .sorted { ($0.run.finished ?? .distantPast) > ($1.run.finished ?? .distantPast) }
    }

    /// What the popup shows.
    var popups: [UnreadRoutine] { unreadRoutines.filter { announced.contains($0.id) } }

    /// Closes the popup; the run stays unread in the dock and the sidebar.
    func dismissPopup(_ id: String) {
        announced.remove(id)
        onChange?()
    }

    /// Every run seen (closing the Routines screen).
    func markSeen() {
        announced = []
        seenUpTo = Date()
        UserDefaults.standard.set(seenUpTo.timeIntervalSince1970, forKey: "routineRunsSeen")
        onChange?()
    }

    /// One routine's runs seen (it's open in the main window).
    func markSeen(_ id: String) {
        guard unread(of: id) > 0 else { return }
        announced.remove(id)
        seen[id] = Date()
        UserDefaults.standard.set(seen.mapValues(\.timeIntervalSince1970), forKey: "routineSeen")
        onChange?()
    }

    /// A run that says it's running but whose helper is gone (the Mac slept or it was killed).
    func isCutOff(_ run: RoutineRun) -> Bool { run.isCutOff { kill($0, 0) == 0 } }

    func save(_ routine: Routine) {
        do {
            try Routines.save(routine)
            try Routines.install(routine, helper: helper)
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func setEnabled(_ routine: Routine, _ on: Bool) {
        var r = routine
        r.enabled = on
        save(r)
    }

    func delete(_ routine: Routine) {
        Routines.uninstall(routine.id)
        Routines.delete(routine.id)
        reload()
    }

    /// Runs it now, in the background; it keeps going if Deck quits.
    func runNow(_ routine: Routine) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["run", routine.id]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { lastError = "Couldn't start the run: \(error.localizedDescription)" }
    }

    /// Your message to a finished run: Claude continues that conversation in the background.
    func reply(to run: RoutineRun, _ message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["reply", run.routine, run.id, message]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { lastError = "Couldn't send it: \(error.localizedDescription)" }
    }

    /// Daily routines that were due while the Mac was off run once now.
    private func catchUp() {
        for r in routines where Routines.missed(r, lastRun: runs(of: r.id).first?.started) {
            DebugLog.write("routine catch-up \(r.name)")
            runNow(r)
        }
    }

    static func outcome(_ run: RoutineRun) -> String {
        switch run.status {
        case .succeeded: "Routine finished"
        case .failed: "Routine failed"
        case .timedOut: "Routine hit its time limit"
        case .running: ""
        }
    }
}
