import Foundation

func ciStatusTests() {
    test("CI: gh pr checks output sums up to one state, naming what failed") {
        let row = { (name: String, bucket: String) in #"{"name":"\#(name)","state":"X","bucket":"\#(bucket)","link":"https://x"}"# }
        let failing = "[" + [row("lint", "pass"), row("e2e", "fail"), row("build", "pending"), row("deploy", "cancel")].joined(separator: ",") + "]"
        expectEqual(CIChecks.parse(checks: failing), CIChecks(state: .failing, failing: ["e2e", "deploy"]))
        expectEqual(CIChecks.parse(checks: "[\(row("lint", "pass")),\(row("build", "pending"))]")?.state, .pending)
        expectEqual(CIChecks.parse(checks: "[\(row("lint", "pass")),\(row("docs", "skipping"))]"), CIChecks(state: .passing))
        expectEqual(CIChecks.parse(checks: "[\(row("docs", "skipping"))]")?.state, CIState.none)
        expectEqual(CIChecks.parse(checks: "[]")?.state, CIState.none)
        expect(CIChecks.parse(checks: "no checks reported on the 'x' branch") == nil)
        expect(CIChecks.parse(checks: "{}") == nil)
        // No bucket (older gh) or no name: sorted from the state.
        expectEqual(CIChecks.parse(checks: #"[{"state":"FAILURE"},{"name":"b","state":"SUCCESS"}]"#), CIChecks(state: .failing, failing: ["check"]))
    }

    test("CI: check states sort into buckets") {
        for s in ["SUCCESS", "pass", "PASSED"] { expectEqual(CIChecks.bucket(state: s), "pass") }
        for s in ["FAILURE", "fail", "FAILED", "ERROR", "TIMED_OUT", "action_required", "STARTUP_FAILURE"] { expectEqual(CIChecks.bucket(state: s), "fail") }
        for s in ["CANCELLED", "canceled"] { expectEqual(CIChecks.bucket(state: s), "cancel") }
        for s in ["SKIPPED", "NEUTRAL", "STALE"] { expectEqual(CIChecks.bucket(state: s), "skipping") }
        for s in ["IN_PROGRESS", "QUEUED", ""] { expectEqual(CIChecks.bucket(state: s), "pending") }
        expectEqual(CIChecks.bucket(state: nil), "pending")
    }

    test("CI: gh run list output, latest run of each workflow on the branch") {
        let runs = """
        [{"status":"in_progress","conclusion":"","headBranch":"feat","workflowName":"Tests","url":"u1"},
         {"status":"completed","conclusion":"failure","headBranch":"feat","workflowName":"Tests","url":"u2"},
         {"status":"completed","conclusion":"success","headBranch":"feat","workflowName":"Lint","url":"u3"},
         {"status":"completed","conclusion":"failure","headBranch":"main","workflowName":"Deploy","url":"u4"}]
        """
        expectEqual(CIChecks.parse(runs: runs, branch: "feat"), CIChecks(state: .pending))
        expectEqual(CIChecks.parse(runs: runs), CIChecks(state: .failing, failing: ["Deploy"]))
        expectEqual(CIChecks.parse(runs: runs, branch: "other"), CIChecks(state: .none))
        let done = #"[{"status":"completed","conclusion":"success","headBranch":"feat"},{"status":"completed","conclusion":"timed_out","headBranch":"feat","workflowName":"Slow"}]"#
        expectEqual(CIChecks.parse(runs: done, branch: "feat"), CIChecks(state: .failing, failing: ["Slow"]))
        expectEqual(CIChecks.parse(runs: #"[{"status":"completed","conclusion":"success","workflowName":"CI"}]"#)?.state, .passing)
        expect(CIChecks.parse(runs: "not json") == nil)
    }

    test("CI: the PR for a branch") {
        expectEqual(CIPullRequest.parse(#"{"number":482,"url":"https://github.com/o/r/pull/482","headRefName":"feat","state":"OPEN","isDraft":false}"#),
                    CIPullRequest(number: 482, url: "https://github.com/o/r/pull/482", branch: "feat", state: .open))
        expectEqual(CIPullRequest.parse(#"{"number":1,"state":"OPEN","isDraft":true}"#)?.state, .draft)
        expectEqual(CIPullRequest.parse(#"{"number":2,"state":"MERGED","isDraft":true}"#)?.state, .merged)
        expectEqual(CIPullRequest.parse(#"{"number":3}"#)?.state, .open)
        expect(CIPullRequest.parse(#"{"title":"no number"}"#) == nil)
        expect(CIPullRequest.parse("no pull requests found for branch \"feat\"") == nil)
    }

    test("CI: a deploy command's result") {
        expectEqual(DeployStatus.from(exitCode: 0, output: "checking…\n  v1.8.2 is live  \n\n"), DeployStatus(deployed: true, detail: "v1.8.2 is live"))
        expectEqual(DeployStatus.from(exitCode: 1, output: ""), DeployStatus(deployed: false, detail: nil))
        expectEqual(DeployStatus.from(exitCode: 3, output: String(repeating: "x", count: 300)).detail?.count, 200)
    }

    test("CI: what counts as a flip") {
        expectEqual(CIStatus.flip(from: .pending, to: .passing), .wentGreen)
        expectEqual(CIStatus.flip(from: .failing, to: .passing), .wentGreen)
        expectEqual(CIStatus.flip(from: .pending, to: .failing), .wentRed)
        expectEqual(CIStatus.flip(from: .passing, to: .failing), .wentRed)
        for (a, b) in [(CIState.passing, CIState.pending), (.failing, .pending), (.none, .passing), (.none, .failing),
                       (.passing, .passing), (.failing, .failing), (.pending, .pending), (.passing, .none)] {
            expect(CIStatus.flip(from: a, to: b) == nil, "\(a) → \(b)")
        }
        let pr = CIPullRequest(number: 7, url: nil, branch: "b", state: .open)
        let pending = CIStatus(pr: pr, checks: CIChecks(state: .pending), deploy: DeployStatus(deployed: false))
        var green = pending
        green.checks = CIChecks(state: .passing)
        green.deploy = DeployStatus(deployed: true)
        expectEqual(CIStatus.flips(from: nil, to: green), [])
        expectEqual(CIStatus.flips(from: pending, to: green), [.wentGreen, .deployed])
        expectEqual(CIStatus.flips(from: green, to: pending), [.deployFailed])
        var otherPR = green
        otherPR.pr?.number = 8
        expectEqual(CIStatus.flips(from: pending, to: otherPR), [.deployed])
        var noDeploy = green
        noDeploy.deploy = nil
        expectEqual(CIStatus.flips(from: pending, to: noDeploy), [.wentGreen])
        expectEqual(pending.pollInterval, 60)
        expectEqual(green.pollInterval, 300)
        expect(!pending.isEmpty)
        expect(CIStatus().isEmpty)
        expect(!CIStatus(deploy: DeployStatus(deployed: true)).isEmpty)
    }

    test("CI: alerts read as one line, and dismiss one at a time") {
        let pr = CIPullRequest(number: 482, url: nil, branch: nil, state: .open)
        let at = Date(timeIntervalSince1970: 100)
        func alert(_ flip: CIFlip, failing: [String] = [], deploy: DeployStatus? = nil, pr: CIPullRequest? = pr) -> CIAlert {
            CIAlert(folder: "/r", flip: flip, status: CIStatus(pr: pr, checks: CIChecks(state: .failing, failing: failing), deploy: deploy), at: at)
        }
        expectEqual(alert(.wentGreen).summary, "PR #482: all checks passed")
        expectEqual(alert(.wentGreen, pr: nil).summary, "This branch: all checks passed")
        expectEqual(alert(.wentRed, failing: ["e2e"]).summary, "PR #482: 1 check failed (e2e)")
        expectEqual(alert(.wentRed, failing: ["e2e", "lint"]).summary, "PR #482: 2 checks failed (e2e, lint)")
        expectEqual(alert(.wentRed).summary, "PR #482: 0 checks failed")
        expectEqual(alert(.deployed, deploy: DeployStatus(deployed: true, detail: "v2 live")).summary, "Deployed: v2 live")
        expectEqual(alert(.deployed).summary, "Deployed")
        expectEqual(alert(.deployFailed, deploy: DeployStatus(deployed: false, detail: "503")).summary, "Deploy check failed: 503")
        expectEqual(alert(.deployFailed).summary, "Deploy check failed")
        expectEqual(alert(.wentGreen).key, "ci:/r:wentGreen:100.0")
    }

    test("CI: alerts in Needs You, on a running session in that folder") {
        let a = Session(sessionId: "a", pid: 1, cwd: "/r", name: "a", title: nil, status: .idle, waitingFor: nil, updatedAt: Date(), transcriptURL: nil)
        let w = Session(sessionId: "w", pid: 1, cwd: "/w", name: "w", title: nil, status: .waiting, waitingFor: nil, updatedAt: Date(), transcriptURL: nil)
        let red = CIAlert(folder: "/r", flip: .wentRed, status: CIStatus(), at: Date(timeIntervalSince1970: 1))
        let gone = CIAlert(folder: "/gone", flip: .wentGreen, status: CIStatus(), at: Date(timeIntervalSince1970: 2))
        let hidden = CIAlert(folder: "/r", flip: .wentGreen, status: CIStatus(), at: Date(timeIntervalSince1970: 3))
        let items = Inbox.items(live: [a, w], sent: [], dismissed: [hidden.key], ci: [red, gone, hidden])
        expectEqual(items.map(\.id), ["prompt:w", "ci:/r:wentRed:1.0:a"])
        expectEqual(items.last?.session.sessionId, "a")
    }

    test("CI: the buttons' messages") {
        let pr = CIPullRequest(number: 482, url: nil, branch: nil, state: .open)
        let red = CIStatus(pr: pr, checks: CIChecks(state: .failing, failing: ["e2e", "lint"]))
        expectEqual(CIAction.fixChecks.message(for: red), "These checks are failing: e2e, lint on PR #482. Look at why (`gh pr checks 482`), fix it, and push.")
        expectEqual(CIAction.fixChecks.message(for: nil), "CI is failing on the PR. Look at why (`gh pr checks`), fix it, and push.")
        expectEqual(CIAction.push.message(for: red), "Commit what's ready and push this branch.")
        expect(CIAction.mergeWhenGreen.message(for: red).hasPrefix("Wait for the checks on PR #482 to pass (`gh pr checks 482` --watch)"))
        expectEqual(CIAction.allCases.map(\.title), ["Fix Failing Checks", "Push", "Merge When Green"])
    }

    test("CI: repo root, from a folder inside it or a worktree") {
        let box = Sandbox(); defer { box.cleanup() }
        let repo = box.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        let tree = box.write("wt/.git", "gitdir: /x").deletingLastPathComponent()
        expectEqual(CIStatus.repoRoot(for: repo.appendingPathComponent("src/deep").path), repo.standardizedFileURL.path)
        expectEqual(CIStatus.repoRoot(for: tree.path), tree.standardizedFileURL.path)
        expect(CIStatus.repoRoot(for: "/") == nil)
    }

    test("CI: deploy commands per repo, kept on disk") {
        let box = Sandbox(); defer { box.cleanup() }
        DeployCommands.dir = box.root.appendingPathComponent("deck")
        expectEqual(DeployCommands.all(), [:])
        DeployCommands.set("  ./scripts/deployed.sh  ", for: "/r")
        DeployCommands.set("curl -sf https://x/health", for: "/s")
        expectEqual(DeployCommands.command(for: "/r"), "./scripts/deployed.sh")
        DeployCommands.set(" ", for: "/s")
        DeployCommands.set(nil, for: "/none")
        expectEqual(DeployCommands.all(), ["/r": "./scripts/deployed.sh"])
        box.write("deck/deploy-commands.json", "{broken")
        expectEqual(DeployCommands.all(), [:])
    }

    test("CI: made-up state for screenshots") {
        let at = Date(timeIntervalSince1970: 9)
        let demo = CIStatus.demo(#"{"orbit-api":{"pr":482,"checks":"failing","failing":["e2e"],"deployed":true,"deployDetail":"v1.8 live","alert":true},"orbit-web":{}}"#, now: at)
        let api = demo["orbit-api"]
        expectEqual(api?.status.pr?.number, 482)
        expectEqual(api?.status.pr?.url, "https://github.com/example/repo/pull/482")
        expectEqual(api?.status.checks, CIChecks(state: .failing, failing: ["e2e"]))
        expectEqual(api?.status.deploy, DeployStatus(deployed: true, detail: "v1.8 live"))
        expectEqual(api?.alert, true)
        expect(demo["orbit-web"]?.status == CIStatus(checkedAt: at))
        expectEqual(demo["orbit-web"]?.alert, false)
        expect(CIStatus.demo("nope").isEmpty)
    }
}
