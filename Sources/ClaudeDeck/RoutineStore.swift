import AppKit
import Observation
import UserNotifications

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
    /// Called when unread runs change (for the Dock badge).
    var onChange: (() -> Void)?

    @ObservationIgnored private var watcher: FileWatcher?
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
        catchUp()
    }

    func reload() {
        routines = Routines.load()
        runs = Routines.runs()
        if let known {
            for run in runs where run.status != .running && known[run.id] != run.status
                && (known[run.id] == .running || known[run.id] == nil) && isUnread(run) {
                notify(run)
            }
        }
        known = Dictionary(runs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        onChange?()
    }

    func runs(of id: String) -> [RoutineRun] { runs.filter { $0.routine == id } }
    func routine(_ id: String) -> Routine? { routines.first { $0.id == id } }

    /// Finished runs you haven't looked at.
    var unread: Int { runs.filter(isUnread).count }
    func unread(of id: String) -> Int { runs(of: id).filter(isUnread).count }
    func isUnread(_ run: RoutineRun) -> Bool {
        (run.finished ?? .distantPast) > max(seenUpTo, seen[run.routine] ?? .distantPast)
    }

    /// Every run seen (closing the Routines screen).
    func markSeen() {
        seenUpTo = Date()
        UserDefaults.standard.set(seenUpTo.timeIntervalSince1970, forKey: "routineRunsSeen")
        onChange?()
    }

    /// One routine's runs seen (it's open in the main window).
    func markSeen(_ id: String) {
        guard unread(of: id) > 0 else { return }
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

    /// Daily routines that were due while the Mac was off run once now.
    private func catchUp() {
        for r in routines where Routines.missed(r, lastRun: runs(of: r.id).first?.started) {
            DebugLog.write("routine catch-up \(r.name)")
            runNow(r)
        }
    }

    private func notify(_ run: RoutineRun) {
        guard let routine = routine(run.routine) else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.subtitle = switch run.status {
        case .succeeded: "Routine finished"
        case .failed: "Routine failed"
        case .timedOut: "Routine hit its time limit"
        case .running: ""
        }
        content.body = String((run.result ?? "").prefix(300))
        content.userInfo = ["routineRun": run.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "routine-" + run.id, content: content, trigger: nil))
    }
}
