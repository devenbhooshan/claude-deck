import Foundation

/// Where a branch's CI stands, summed up from its checks or workflow runs.
enum CIState: String, Codable, Equatable {
    /// No PR, or a PR with no checks (or only skipped ones).
    case none, pending, passing, failing
}

/// CI results for one PR: the overall state and the names of the checks that failed.
struct CIChecks: Equatable, Codable {
    var state: CIState
    var failing: [String] = []

    static let checkFields = "name,state,bucket,link"
    static let runFields = "status,conclusion,headBranch,workflowName,url"

    /// `gh pr checks --json name,state,bucket,link`. Any failed or cancelled check makes it
    /// failing, else any unfinished one pending; nil when the output isn't that JSON.
    static func parse(checks json: String) -> CIChecks? {
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
        let results = rows.map { row -> (String, String) in
            let bucket = (row["bucket"] as? String)?.lowercased() ?? Self.bucket(state: row["state"] as? String)
            return (row["name"] as? String ?? "check", bucket)
        }
        return summarize(results)
    }

    /// `gh pr checks` sorts each check's state into a bucket; older versions don't, so sort it here.
    static func bucket(state: String?) -> String {
        switch state?.uppercased() {
        case "SUCCESS", "PASS", "PASSED": "pass"
        case "FAILURE", "FAIL", "FAILED", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": "fail"
        case "CANCELLED", "CANCELED": "cancel"
        case "SKIPPED", "NEUTRAL", "STALE": "skipping"
        default: "pending"
        }
    }

    /// `gh run list --json status,conclusion,headBranch,workflowName,url`, newest first: the latest
    /// run of each workflow on `branch` (every branch when nil).
    static func parse(runs json: String, branch: String? = nil) -> CIChecks? {
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var results: [(String, String)] = []
        for row in rows {
            if let branch, row["headBranch"] as? String != branch { continue }
            let name = row["workflowName"] as? String ?? "workflow"
            guard seen.insert(name).inserted else { continue }
            let done = (row["status"] as? String)?.lowercased() == "completed"
            results.append((name, done ? Self.bucket(state: row["conclusion"] as? String) : "pending"))
        }
        return summarize(results)
    }

    private static func summarize(_ results: [(name: String, bucket: String)]) -> CIChecks {
        let failing = results.filter { $0.bucket == "fail" || $0.bucket == "cancel" }.map(\.name)
        if !failing.isEmpty { return CIChecks(state: .failing, failing: failing) }
        if results.contains(where: { $0.bucket == "pending" }) { return CIChecks(state: .pending) }
        if results.contains(where: { $0.bucket == "pass" }) { return CIChecks(state: .passing) }
        return CIChecks(state: .none)
    }
}

/// The PR open for a session's branch, from `gh pr view --json number,url,headRefName,state,isDraft`.
struct CIPullRequest: Equatable, Codable {
    var number: Int
    var url: String?
    var branch: String?
    var state: PRInfo.State

    static let fields = "number,url,headRefName,state,isDraft"

    static func parse(_ json: String) -> CIPullRequest? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let number = obj["number"] as? Int else { return nil }
        var state = (obj["state"] as? String).flatMap(PRInfo.State.init(rawValue:)) ?? .open
        if state == .open, obj["isDraft"] as? Bool == true { state = .draft }
        return CIPullRequest(number: number, url: obj["url"] as? String, branch: obj["headRefName"] as? String, state: state)
    }
}

/// What a repo's deploy-status command said: exit 0 means deployed.
struct DeployStatus: Equatable, Codable {
    var deployed: Bool
    /// Its last line of output.
    var detail: String?

    static func from(exitCode: Int32, output: String) -> DeployStatus {
        let last = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return DeployStatus(deployed: exitCode == 0, detail: last.map { String($0.prefix(200)) })
    }
}

/// A change worth telling you about.
enum CIFlip: String, Codable, Equatable {
    case wentGreen, wentRed, deployed, deployFailed
}

/// One session folder's PR, checks and deploy state.
struct CIStatus: Equatable, Codable {
    var pr: CIPullRequest?
    var checks = CIChecks(state: .none)
    var deploy: DeployStatus?
    var checkedAt = Date()

    /// Anything worth a chip: a PR or a deploy result.
    var isEmpty: Bool { pr == nil && deploy == nil }

    /// While checks run, look every minute; once they settle, every five.
    var pollInterval: TimeInterval { checks.state == .pending ? 60 : 300 }

    /// What changed from `old` worth raising: checks finishing (or turning) green or red, and a
    /// deploy landing or breaking. Nothing on the first look, or when the PR itself changed.
    static func flips(from old: CIStatus?, to new: CIStatus) -> [CIFlip] {
        guard let old else { return [] }
        var flips: [CIFlip] = []
        if old.pr?.number == new.pr?.number, let f = flip(from: old.checks.state, to: new.checks.state) { flips.append(f) }
        if let was = old.deploy?.deployed, let now = new.deploy?.deployed, was != now {
            flips.append(now ? .deployed : .deployFailed)
        }
        return flips
    }

    /// Pending or red → green is good news, pending or green → red bad; a new run starting
    /// (→ pending) or going away (→ none) isn't news.
    static func flip(from old: CIState, to new: CIState) -> CIFlip? {
        switch (old, new) {
        case (.pending, .passing), (.failing, .passing): .wentGreen
        case (.pending, .failing), (.passing, .failing): .wentRed
        default: nil
        }
    }

    /// The folder holding `.git` (a directory, or a file in a worktree) at or above `path`.
    static func repoRoot(for path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return url.path
    }

    /// The `demoCIStatus` default used by scripts/screenshots.py: folder name → made-up state,
    /// e.g. `{"orbit-api": {"pr": 482, "checks": "failing", "failing": ["e2e"], "deployed": false,
    /// "deployDetail": "v1.8.2 live", "alert": true}}`. Entries with `alert` also raise a Needs You item.
    static func demo(_ json: String, now: Date = Date()) -> [String: (status: CIStatus, alert: Bool)] {
        struct Entry: Decodable {
            var pr: Int?
            var checks: CIState?
            var failing: [String]?
            var deployed: Bool?
            var deployDetail: String?
            var alert: Bool?
        }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: Data(json.utf8)) else { return [:] }
        return entries.mapValues { e in
            let pr = e.pr.map { CIPullRequest(number: $0, url: "https://github.com/example/repo/pull/\($0)", branch: nil, state: .open) }
            let deploy = e.deployed.map { DeployStatus(deployed: $0, detail: e.deployDetail) }
            let status = CIStatus(pr: pr, checks: CIChecks(state: e.checks ?? .none, failing: e.failing ?? []), deploy: deploy, checkedAt: now)
            return (status, e.alert ?? false)
        }
    }
}

/// A flip shown in Needs You until dismissed.
struct CIAlert: Equatable, Codable {
    var folder: String
    var flip: CIFlip
    var status: CIStatus
    var at: Date

    /// Dismissing it hides this alert, not later ones.
    var key: String { "ci:\(folder):\(flip.rawValue):\(at.timeIntervalSince1970)" }

    /// One line for the Needs You card.
    var summary: String {
        let pr = status.pr.map { "PR #\($0.number)" } ?? "This branch"
        switch flip {
        case .wentGreen: return "\(pr): all checks passed"
        case .wentRed:
            let names = status.checks.failing
            return "\(pr): \(names.count == 1 ? "1 check" : "\(names.count) checks") failed" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
        case .deployed: return "Deployed" + (status.deploy?.detail.map { ": \($0)" } ?? "")
        case .deployFailed: return "Deploy check failed" + (status.deploy?.detail.map { ": \($0)" } ?? "")
        }
    }
}

/// Messages the CI chip's buttons put in a session's message box, for you to edit and send.
enum CIAction: String, CaseIterable {
    case fixChecks, push, mergeWhenGreen

    var title: String {
        switch self {
        case .fixChecks: "Fix Failing Checks"
        case .push: "Push"
        case .mergeWhenGreen: "Merge When Green"
        }
    }

    func message(for status: CIStatus?) -> String {
        let pr = status?.pr.map { "PR #\($0.number)" } ?? "the PR"
        let checks = status?.pr.map { "`gh pr checks \($0.number)`" } ?? "`gh pr checks`"
        switch self {
        case .fixChecks:
            let names = status?.checks.failing ?? []
            let which = names.isEmpty ? "CI is failing" : "These checks are failing: \(names.joined(separator: ", "))"
            return "\(which) on \(pr). Look at why (\(checks)), fix it, and push."
        case .push:
            return "Commit what's ready and push this branch."
        case .mergeWhenGreen:
            return "Wait for the checks on \(pr) to pass (\(checks) --watch), then merge it. If one fails, stop and tell me why."
        }
    }
}

/// Each repo's optional deploy-status command (repo folder → shell command), in
/// Application Support/ClaudeDeck/deploy-commands.json.
enum DeployCommands {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck")
    static var fileURL: URL { dir.appendingPathComponent("deploy-commands.json") }

    static func all() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let commands = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return commands
    }

    static func command(for repo: String) -> String? { all()[repo] }

    /// Sets (or, when blank, removes) a repo's command.
    static func set(_ command: String?, for repo: String) {
        var commands = all()
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        commands[repo] = trimmed.isEmpty ? nil : trimmed
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(commands).write(to: fileURL, options: .atomic)
    }
}
