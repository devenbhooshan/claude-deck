import Foundation

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let ten: TimeInterval = 600

private func fleet(_ name: String, _ status: SessionStatus = .idle, pid: Int32? = 1, active: Date? = nil,
                   since: Date? = nil, replies: [String] = []) -> Session {
    var s = Session(sessionId: name, pid: pid, cwd: "/tmp/\(name)", name: name, title: nil, status: status,
                    waitingFor: nil, updatedAt: t0, transcriptURL: nil, statusSince: since)
    s.activeAt = active
    s.replyTexts = replies
    s.replies = replies.indices.map { t0.addingTimeInterval(Double($0)) }
    return s
}

func fleetDigestTests() {
    test("stuck: working, nothing written for the threshold, no background command") {
        let quiet = fleet("a", .busy, active: t0, since: t0.addingTimeInterval(-60))
        expectEqual(FleetDigest.stuckSince(quiet, now: t0.addingTimeInterval(ten), threshold: ten), t0)
        expect(FleetDigest.stuckSince(quiet, now: t0.addingTimeInterval(ten - 1), threshold: ten) == nil)
        // The newer of the transcript's change and the status change counts.
        let fresh = fleet("a", .busy, active: t0, since: t0.addingTimeInterval(300))
        expect(FleetDigest.stuckSince(fresh, now: t0.addingTimeInterval(ten), threshold: ten) == nil)
        expect(FleetDigest.stuckSince(fleet("a", .busy), now: t0, threshold: 0) == nil, "nothing to go on")
        expect(FleetDigest.stuckSince(fleet("a", .idle, active: t0), now: t0.addingTimeInterval(ten), threshold: ten) == nil)
        expect(FleetDigest.stuckSince(fleet("a", .busy, pid: nil, active: t0), now: t0.addingTimeInterval(ten), threshold: ten) == nil)
        var running = quiet
        running.background = [BackgroundTask(pid: 2, parent: 1, command: "make test", started: t0, isServer: false)]
        expect(FleetDigest.stuckSince(running, now: t0.addingTimeInterval(ten), threshold: ten) == nil)
        running.background = [BackgroundTask(pid: 2, parent: 1, command: "bin/dev", started: t0, isServer: true)]
        expect(FleetDigest.stuckSince(running, now: t0.addingTimeInterval(ten), threshold: ten) != nil, "a server explains nothing")
    }

    test("fleet events: only what changed since the last poll") {
        let now = t0.addingTimeInterval(ten)
        let old = FleetDigest.snapshot([fleet("api", .busy), fleet("web"), fleet("search", .busy, active: now), fleet("gone", .busy),
                                        fleet("quit"), fleet("cos"), fleet("muted"), fleet("ended", .waiting), fleet("swap", .busy),
                                        fleet("old", .busy, pid: 7), fleet("still", .busy, active: t0)], now: now, threshold: ten)
        expectEqual(old.stuck, ["still"])
        let new = FleetDigest.snapshot([fleet("api"), fleet("web", .waiting), fleet("search", .busy, active: t0), fleet("cos", .waiting),
                                        fleet("muted", .waiting), fleet("new"), fleet("back"), fleet("old", .busy, pid: 8),
                                        fleet("still", .busy, active: t0)], now: now, threshold: ten)
        let context = FleetDigest.Context(excluded: ["cos", "muted"], endedByDeck: ["ended"], restartedByDeck: ["back"], replaced: ["swap"])
        let events = FleetDigest.events(from: old, to: new, now: now, threshold: ten, context: context)
        expectEqual(events.map { FleetDigest.phrase($0, now: now) },
                    ["api finished", "web waiting on you", "search stuck 10m", "new started", "back restarted", "old restarted",
                     "gone ended unexpectedly", "quit ended", "ended ended"])
        expectEqual(FleetSnapshot(), FleetSnapshot(sessions: [], stuck: []))
        expect(FleetDigest.events(from: nil, to: new, now: now, threshold: ten).isEmpty, "the first poll is a baseline")
        expect(FleetDigest.events(from: new, to: new, now: now, threshold: ten).isEmpty, "no change, no events")
        // A resumed session can briefly have two records: the first one counts.
        let twice = FleetSnapshot(sessions: [fleet("a", .busy), fleet("a")])
        expectEqual(FleetDigest.events(from: twice, to: FleetSnapshot(sessions: [fleet("a")]), now: now, threshold: ten),
                    [.finished(fleet("a"))])
    }

    test("fleet batch: newest state wins, stale events drop, one line") {
        let now = t0.addingTimeInterval(12 * 60)
        let api = fleet("api"), web = fleet("web", .waiting)
        let merged = FleetDigest.merge([.waiting(web), .ciFlipped(api, "CI passed")],
                                       [.finished(api), .ciFlipped(api, "CI failed"), .finished(web)])
        expectEqual(merged, [.finished(web), .ciFlipped(api, "CI failed"), .finished(api)])
        expectEqual(merged.map(\.key), ["web", "ci:api", "api"])

        var waiting = fleet("web", .waiting)
        waiting.pendingTool = ToolCall(id: "1", name: "Bash", summary: "rm")
        var renamed = fleet("api")
        renamed.title = "orbit-api"
        let stuck = fleet("search", .busy, active: t0)
        let batch: [FleetEvent] = [.finished(api), .waiting(fleet("web")), .stuck(fleet("search", .busy), since: t0),
                                   .restarted(fleet("r")), .started(fleet("n")), .ended(fleet("e"), unexpected: true),
                                   .ciFlipped(fleet("ci"), "CI failed on #4"), .ciFlipped(fleet("gone"), "deploy failed"),
                                   .finished(fleet("busy")), .waiting(fleet("answered")), .stuck(fleet("moving"), since: t0),
                                   .restarted(fleet("x")), .started(fleet("y")), .ended(fleet("back"), unexpected: false)]
        let live = [renamed, waiting, stuck, fleet("r"), fleet("n"), fleet("ci"), fleet("busy", .busy), fleet("answered"),
                    fleet("moving", .busy, active: now), fleet("back")]
        let current = FleetDigest.current(batch, live: live, now: now, threshold: ten)
        expectEqual(current.map { FleetDigest.phrase($0, now: now) },
                    ["orbit-api finished", "web waiting on you (Bash)", "search stuck 12m", "r restarted", "n started",
                     "e ended unexpectedly", "ci CI failed on #4", "gone deploy failed"])
        expectEqual(FleetDigest.line(Array(current.prefix(3)), now: now),
                    "[Claude Deck] Fleet: orbit-api finished · web waiting on you (Bash) · search stuck 12m")
        expect(FleetDigest.line([], now: now) == nil)
        var asked = fleet("w", .waiting)
        asked.waitingFor = "permission prompt"
        expectEqual(FleetDigest.phrase(.waiting(asked), now: now), "w waiting on you (permission prompt)")
        expectEqual(FleetDigest.minutes(since: now, now: t0), 0)
    }

    test("fleet line goes only to an idle coordinator, at most every two minutes") {
        let batch: [FleetEvent] = [.finished(fleet("api"))]
        let now = t0
        expect(FleetDigest.shouldDeliver(batch, coordinator: fleet("cos"), lastSent: nil, now: now))
        expect(FleetDigest.shouldDeliver(batch, coordinator: fleet("cos", .background), lastSent: now.addingTimeInterval(-120), now: now))
        expect(!FleetDigest.shouldDeliver(batch, coordinator: fleet("cos"), lastSent: now.addingTimeInterval(-119), now: now))
        expect(!FleetDigest.shouldDeliver([], coordinator: fleet("cos"), lastSent: nil, now: now))
        expect(!FleetDigest.shouldDeliver(batch, coordinator: nil, lastSent: nil, now: now))
        expect(!FleetDigest.shouldDeliver(batch, coordinator: fleet("cos", .busy), lastSent: nil, now: now))
        expect(!FleetDigest.shouldDeliver(batch, coordinator: fleet("cos", .waiting), lastSent: nil, now: now))
        expect(!FleetDigest.shouldDeliver(batch, coordinator: fleet("cos", pid: nil), lastSent: nil, now: now))
        expectEqual(FleetDigest.defaultStuckMinutes, 10)
    }

    test("inbox: finished replies you haven't read, and errors") {
        let done = fleet("done", replies: ["Fixed it.\n\nAll 50 runs pass."])
        let read = fleet("read", replies: ["Done."])
        let asks = fleet("asks", replies: ["Should I?"])
        let failed = fleet("failed", replies: ["Working.", "API Error: 529 overloaded"])
        let longError = fleet("long", replies: ["API Error: " + String(repeating: "x", count: 400)])
        let busyError = fleet("busyerr", .busy, replies: ["API Error: 500"])
        var drafted = fleet("drafted", replies: ["```send-to api\ngo\n```"])
        drafted.handoffs = [Handoff(target: "api", text: "go")]
        let crashed = Inbox.Failure(session: fleet("crashed", .busy), at: t0)
        let prompted = Inbox.Failure(session: fleet("prompted", .waiting), at: t0)
        let resumed = Inbox.Failure(session: fleet("resumed", .busy), at: t0)
        let hidden = Inbox.Failure(session: fleet("hidden", .busy), at: t0)
        let unread: (Session) -> Bool = { $0.sessionId != "read" }
        let items = Inbox.items(live: [done, read, asks, failed, longError, busyError, drafted, fleet("resumed"), fleet("w", .waiting)],
                                sent: [], dismissed: [hidden.key], failures: [crashed, prompted, resumed, hidden], isUnread: unread)
        expectEqual(items.map(\.id), ["prompt:w", Inbox.errorKey(failed), Inbox.errorKey(longError), crashed.key, prompted.key,
                                      "handoff:drafted:" + Handoff(target: "api", text: "go").key, "question:asks", "completed:done"])
        expectEqual(crashed.text, "Ended while working")
        expectEqual(prompted.text, "Ended while waiting on you")
        expectEqual(crashed.key, "error:crashed:1000000.0")
        if case .completed(_, let text) = items.last { expectEqual(text, "All 50 runs pass.") } else { expect(false) }
        if case .error(_, let text, _) = items[1] { expectEqual(text, "API Error: 529 overloaded") } else { expect(false) }
        if case .error(_, let text, _) = items[2] { expectEqual(text.count, 300) } else { expect(false) }
        expectEqual(items.map(\.session.sessionId), ["w", "failed", "long", "crashed", "prompted", "drafted", "asks", "done"])
        expectEqual(items.map(\.isError), [false, true, true, true, true, false, false, false])
        expectEqual(items.map(\.needsAction), [true, true, true, true, true, true, true, false])
        expectEqual(items.map(\.dismissKey), [nil, Inbox.errorKey(failed), Inbox.errorKey(longError), crashed.key, prompted.key,
                                              Handoff(target: "api", text: "go").key, Inbox.questionKey(asks), Inbox.completedKey(done)])
        expectEqual(Inbox.completedKey(done), "completed:done:1000000.0")
        // Dismissed finished replies and errors stay gone until Claude writes again.
        let after = Inbox.items(live: [done, failed], sent: [], dismissed: [Inbox.completedKey(done), Inbox.errorKey(failed)], isUnread: unread)
        expect(after.isEmpty)
        expectEqual(Inbox.lastParagraph("  \n\n  "), "")
        expect(Inbox.question(in: fleet("blank", replies: ["  "])) == nil)
        expect(Inbox.turnError(in: fleet("none")) == nil)
        expectEqual(Inbox.completedKey(fleet("none")), "completed:none:0.0")
        expectEqual(Inbox.errorKey(fleet("none")), "error:none:0.0")
    }

    test("inbox filters and keyboard steps") {
        let items: [Inbox.Item] = [.prompt(fleet("p", .waiting)), .error(fleet("e"), "x", key: "error:e"),
                                   .question(fleet("q"), "?"), .completed(fleet("c"), "done"), .handoff(from: fleet("h"), Handoff(target: "a", text: "b"))]
        let unread: (Session) -> Bool = { $0.sessionId == "c" }
        expectEqual(items.filter { Inbox.Filter.all.matches($0, isUnread: unread) }.count, 5)
        expectEqual(items.filter { Inbox.Filter.errors.matches($0, isUnread: unread) }.map(\.id), ["error:e"])
        expectEqual(items.filter { Inbox.Filter.unread.matches($0, isUnread: unread) }.map(\.id), ["prompt:p", "error:e", "completed:c"])
        expectEqual(Inbox.Filter.allCases.map(\.label), ["All", "Unread", "Errors"])
        expectEqual(Inbox.Filter.allCases.map(\.id), ["all", "unread", "errors"])
        expectEqual(Inbox.step(items, from: nil, by: 1), "prompt:p")
        expectEqual(Inbox.step(items, from: "gone", by: -1), "prompt:p")
        expectEqual(Inbox.step(items, from: "prompt:p", by: 1), "error:e")
        expectEqual(Inbox.step(items, from: "prompt:p", by: -1), "prompt:p")
        expectEqual(Inbox.step(items, from: "completed:c", by: 5), "handoff:h:" + Handoff(target: "a", text: "b").key)
        expect(Inbox.step([], from: nil, by: 1) == nil)
    }

    test("CI flips: in the fleet line, and as inbox items") {
        expectEqual(FleetDigest.ciText(.wentRed, pr: 412), "PR #412 checks failed")
        expectEqual(FleetDigest.ciText(.wentGreen, pr: nil), "checks passed")
        expectEqual(FleetDigest.ciText(.deployed, pr: 1), "deployed")
        expectEqual(FleetDigest.ciText(.deployFailed, pr: nil), "deploy failed")
        expectEqual(FleetDigest.phrase(.ciFlipped(fleet("api"), FleetDigest.ciText(.wentRed, pr: 412)), now: t0), "api PR #412 checks failed")
        let api = fleet("api")
        let red = CIAlert(folder: api.cwd, flip: .wentRed, status: CIStatus(), at: t0)
        let green = CIAlert(folder: api.cwd, flip: .wentGreen, status: CIStatus(), at: t0)
        let broke = CIAlert(folder: api.cwd, flip: .deployFailed, status: CIStatus(), at: t0)
        let items = Inbox.items(live: [api], sent: [], dismissed: [], ci: [red, green, broke])
        expectEqual(items.map(\.isError), [true, false, true])
        expectEqual(items.map(\.dismissKey), [red.key, green.key, broke.key])
        expect(items.allSatisfy { Inbox.Filter.unread.matches($0, isUnread: { _ in false }) })
    }

    test("live sessions: when the transcript last changed; a quiet working session's commands are looked up") {
        let box = Sandbox(); defer { box.cleanup() }
        let me = getpid()
        box.write("claude/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"q","cwd":"/p","status":"busy"}"#)
        let url = box.jsonl("claude/projects/-p/q.jsonl", [["type": "user", "cwd": "/p"]])
        let job = BackgroundTask(pid: 50, parent: me, command: "make test", started: Date(), isServer: false)
        var reads = 0
        let fresh = SessionLoader.loadLive(cache: [:], tasks: { reads += 1; return [me: [job]] }).0.first!
        expectEqual(reads, 0)
        expect(fresh.activeAt != nil && fresh.background.isEmpty)
        let old = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let quiet = SessionLoader.loadLive(cache: [:], tasks: { reads += 1; return [me: [job]] }).0.first!
        expectEqual(reads, 1)
        expectEqual(quiet.status, .busy)
        expectEqual(quiet.background, [job])
        expectEqual(quiet.activeAt.map { Int($0.timeIntervalSince1970) }, Int(old.timeIntervalSince1970))
    }
}
