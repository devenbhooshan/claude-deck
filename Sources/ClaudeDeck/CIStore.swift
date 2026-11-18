import Foundation
import Observation

/// Each running session's PR checks and deploy state, polled with `gh` (and the repo's own
/// deploy-status command, if you set one) in the background: every minute while checks run,
/// every five once they settle. Keyed by session folder, so sessions sharing one look once.
@MainActor
@Observable
final class CIStore {
    private(set) var status: [String: CIStatus] = [:]
    /// The latest flip per folder, shown in Needs You until dismissed.
    private(set) var alerts: [String: CIAlert] = [:]
    /// Called when a new alert comes in (the fleet feed tells the coordinator).
    var onAlert: ((CIAlert) -> Void)?

    private var due: [String: Date] = [:]
    private var polling: Set<String> = []
    private static let maxPolling = 2

    /// scripts/screenshots.py's made-up state (`-demoCIStatus '{…}'`), only in its demo copy of the app.
    private let demo: [String: (status: CIStatus, alert: Bool)]? = {
        guard Bundle.main.bundleIdentifier == "com.devenbhooshan.claudedeck.demo" else { return nil }
        // Read the raw argument: as a default, a value starting with "{" may be taken for a plist.
        let args = CommandLine.arguments
        let arg = args.firstIndex(of: "-demoCIStatus").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        guard let json = arg ?? UserDefaults.standard.string(forKey: "demoCIStatus") else { return nil }
        return CIStatus.demo(json)
    }()

    func status(for s: Session) -> CIStatus? { status[s.cwd] }

    /// Called with the running sessions on every refresh: starts the looks that are due.
    func refresh(sessions: [Session]) {
        let folders = Set(sessions.map(\.cwd))
        if let demo {
            for s in sessions where status[s.cwd] == nil {
                guard let d = demo[s.projectName] else { continue }
                status[s.cwd] = d.status
                if d.alert { raise(.init(folder: s.cwd, flip: d.status.checks.state == .passing ? .wentGreen : .wentRed, status: d.status, at: Date())) }
            }
            return
        }
        // Forget sessions that ended.
        for key in Set(status.keys).union(due.keys) where !folders.contains(key) {
            status[key] = nil
            due[key] = nil
            alerts[key] = nil
        }
        let now = Date()
        for folder in folders where !polling.contains(folder) && (due[folder] ?? .distantPast) <= now {
            guard polling.count < Self.maxPolling else { break }
            poll(folder)
        }
    }

    /// Looks again now (the chip's Check Now, or after setting a deploy command).
    func checkNow(_ s: Session) {
        guard demo == nil, !polling.contains(s.cwd) else { return }
        poll(s.cwd)
    }

    func deployCommand(for s: Session) -> String? {
        CIStatus.repoRoot(for: s.cwd).flatMap(DeployCommands.command(for:))
    }

    func setDeployCommand(_ command: String, for s: Session) {
        DeployCommands.set(command, for: CIStatus.repoRoot(for: s.cwd) ?? s.cwd)
        checkNow(s)
    }

    func dismiss(_ alert: CIAlert) {
        if alerts[alert.folder] == alert { alerts[alert.folder] = nil }
    }

    private func poll(_ folder: String) {
        polling.insert(folder)
        Task.detached(priority: .utility) {
            let new = Self.look(in: folder)
            await MainActor.run { self.update(folder, new) }
        }
    }

    private func update(_ folder: String, _ new: CIStatus?) {
        polling.remove(folder)
        guard let new else {
            // Not a git repo: look again only now and then (it may become one).
            due[folder] = Date().addingTimeInterval(1800)
            return
        }
        let old = status[folder]
        due[folder] = Date().addingTimeInterval(new.pollInterval)
        if old != new { status[folder] = new }
        if let flip = CIStatus.flips(from: old, to: new).last {
            raise(CIAlert(folder: folder, flip: flip, status: new, at: Date()))
        }
    }

    private func raise(_ alert: CIAlert) {
        alerts[alert.folder] = alert
        onAlert?(alert)
    }

    /// One look, off the main thread: the branch's PR, its checks (or, when it reports none, the
    /// branch's latest workflow runs), and the repo's deploy command. Nil outside a git repo.
    nonisolated private static func look(in folder: String) -> CIStatus? {
        guard let root = CIStatus.repoRoot(for: folder) else { return nil }
        var status = CIStatus()
        if let out = try? ClaudeRunner.gh(["pr", "view", "--json", CIPullRequest.fields], in: folder).get(),
           let pr = CIPullRequest.parse(out) {
            status.pr = pr
            let checks = (try? ClaudeRunner.gh(["pr", "checks", String(pr.number), "--json", CIChecks.checkFields], in: folder).get())
                .flatMap { CIChecks.parse(checks: $0) }
            status.checks = checks ?? CIChecks(state: .none)
            if status.checks.state == .none, let branch = pr.branch,
               let out = try? ClaudeRunner.gh(["run", "list", "--branch", branch, "--limit", "20", "--json", CIChecks.runFields], in: folder).get(),
               let runs = CIChecks.parse(runs: out, branch: branch) {
                status.checks = runs
            }
        }
        if let command = DeployCommands.command(for: root) {
            let result = ClaudeRunner.shell(command, in: root)
            status.deploy = DeployStatus.from(exitCode: result.status, output: result.output)
        }
        return status
    }
}
