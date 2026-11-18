import Foundation

/// A background session (`claude --bg`), as Deck sees it.
private func bgSession(_ id: String, status: SessionStatus = .waiting, pid: Int32? = 1, cwd: String = "/p/app",
                       name: String? = "bg-job", jobId: String? = "j1") -> Session {
    var s = session(id, status: status, pid: pid, cwd: cwd, name: name, waitingFor: status == .waiting ? "permission prompt" : nil,
                    pendingTool: status == .waiting ? ToolCall(id: "t", name: "Bash", summary: "rm -rf build") : nil)
    s.isBackground = true
    s.jobId = jobId
    return s
}

func backgroundAgentTests() {
    test("a background session's record: kind bg and its job id") {
        let box = Sandbox(); defer { box.cleanup() }
        box.write("claude/sessions/1.json", #"{"pid":1,"sessionId":"bg","cwd":"/p/app","kind":"bg","jobId":"a1b2c3","status":"waiting","waitingFor":"permission prompt","startedAt":1}"#)
        box.write("claude/sessions/2.json", #"{"pid":2,"sessionId":"tty","cwd":"/p/app","kind":"interactive","status":"idle","startedAt":2}"#)
        let (live, _) = SessionLoader.loadLive(cache: [:], alive: { _ in true }, tasks: { [:] })
        let bg = live.first { $0.id == "bg" }!, tty = live.first { $0.id == "tty" }!
        expect(bg.isBackground)
        expectEqual(bg.jobId, "a1b2c3")
        expect(!bg.canDrive, "no terminal to drive")
        expect(!tty.isBackground)
        expect(tty.canDrive)
        expect(SessionLoader.record(pid: 1)?.isBackground == true)
        // A job id alone marks it too (a record written before `kind` said so).
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: Data(#"{"pid":3,"sessionId":"x","cwd":"/","jobId":"z9"}"#.utf8))
        expect(decoded.isBackground)
        expect(SessionLoader.record(pid: 2)?.isBackground == false)
    }

    test("Deck never answers a background session's prompt in place") {
        let bg = bgSession("bg")
        expect(SessionNav.isPermission(bg))
        expect(!PromptGuard.canAnswerHere(bg))
        var tty = bg
        tty.isBackground = false
        expect(PromptGuard.canAnswerHere(tty), "the same prompt in a terminal session can be answered")
    }

    test("no terminal is ever picked for a background session, even the only one in its folder") {
        let only = [GhosttyTerminal(id: "T1", name: "✳ bg-job", workingDirectory: "/p/app")]
        // The interactive session's terminal: same folder, and even the session's own name in the title.
        expect(TerminalMatch.find(for: bgSession("bg"), in: only) == nil)
        expect(TerminalMatch.find(for: bgSession("bg"), in: only, preferred: "gone") == nil)
        var tty = bgSession("tty", status: .idle)
        tty.isBackground = false
        expectEqual(TerminalMatch.find(for: tty, in: only)?.id, "T1")
    }

    test("once opened (claude attach), only that window drives it") {
        let terms = [GhosttyTerminal(id: "T1", name: "✳ other", workingDirectory: "/p/app"),
                     GhosttyTerminal(id: "W", name: "✳ bg-job", workingDirectory: "/p/app"),
                     GhosttyTerminal(id: "X", name: "✳ bg-job", workingDirectory: "/p/elsewhere")]
        var bg = bgSession("bg")
        bg.attached = true
        expect(bg.canDrive)
        expect(PromptGuard.canAnswerHere(bg), "answered through its window, like any session")
        expectEqual(TerminalMatch.find(for: bg, in: terms, preferred: "W")?.id, "W")
        // Never by title or by being alone in the folder, and not a window that left the folder.
        expect(TerminalMatch.find(for: bg, in: terms) == nil)
        expect(TerminalMatch.find(for: bg, in: [terms[1]]) == nil)
        expect(TerminalMatch.find(for: bg, in: terms, preferred: "X") == nil)
        // The window closed (or isn't Claude any more): nothing.
        expect(TerminalMatch.find(for: bg, in: [GhosttyTerminal(id: "W", name: "zsh", workingDirectory: "/p/app")], preferred: "W") == nil)
    }

    test("open, stop and remove take only a plain job id") {
        expectEqual(BackgroundAgents.attachCommand("a1b2c3"), "claude attach a1b2c3")
        expectEqual(BackgroundAgents.stopArguments("a1b2c3"), ["stop", "a1b2c3"])
        expectEqual(BackgroundAgents.removeArguments("job_9-x"), ["rm", "job_9-x"])
        for bad in ["", "a b", "a;rm -rf ~", "$(x)", String(repeating: "a", count: 65), "a\nb"] {
            expect(BackgroundAgents.attachCommand(bad) == nil, bad)
            expect(BackgroundAgents.stopArguments(bad) == nil, bad)
            expect(BackgroundAgents.removeArguments(bad) == nil, bad)
        }
        expect(BackgroundAgents.isJobId("-rf"), "passed as its own argument, never through a shell, so a dash is harmless")
    }

    test("claude agents --json --all: parsed, and anything else is nil") {
        let out = """
        [
          {"pid": 2502, "cwd": "/p/app", "kind": "interactive", "startedAt": 1000, "sessionId": "tty", "name": "chief", "status": "idle"},
          {"pid": 77, "cwd": "/p/app", "kind": "background", "startedAt": 2000, "sessionId": "live-bg", "status": "waiting",
           "waitingFor": "permission prompt", "id": "a1b2c3", "state": "blocked"},
          {"cwd": "/p/app", "kind": "background", "startedAt": 3000, "sessionId": "old-bg", "name": "bump", "id": "d4e5f6", "state": "done"},
          {"cwd": "/p/app", "kind": "background", "startedAt": 4000, "id": "nosess", "state": "failed"},
          {"cwd": "/p/app", "kind": "background", "state": "paused"}
        ]
        """
        let agents = BackgroundAgents.parse("warning: something\n" + out)!
        expectEqual(agents.count, 5)
        expect(!agents[0].isBackground)
        expect(agents[1].isBackground)
        expectEqual(agents[1].pid, 77)
        expectEqual(agents[1].agentState, .blocked)
        expectEqual(agents[2].id, "d4e5f6")
        expect(agents[4].agentState == nil, "an unknown state is no state")
        expect(BackgroundAgents.parse("error: unknown command agents") == nil)
        expect(BackgroundAgents.parse("[{\"nope\": 1}]") == nil)
        expectEqual(BackgroundAgents.parse("[]")!, [])
        expect(AgentEntry(cwd: "/", kind: "bg").isBackground)
        expectEqual(BackgroundAgents.listArguments, ["agents", "--json", "--all"])
        expectEqual(BackgroundAgents.pollInterval, 5)
        expectEqual([AgentState.working, .blocked, .done, .failed, .stopped].map(\.label),
                    ["Working", "Blocked", "Done", "Failed", "Stopped"])
    }

    test("merged with the running sessions: job ids and states, and exited background sessions listed") {
        let box = Sandbox(); defer { box.cleanup() }
        box.jsonl("claude/projects/-p-app/old-bg.jsonl", [["type": "ai-title", "aiTitle": "Bump the SDK"]])
        let agents = [
            AgentEntry(cwd: "/p/app", kind: "interactive", pid: 1, sessionId: "tty"),
            AgentEntry(cwd: "/p/app", kind: "background", startedAt: 2000, pid: 77, sessionId: "live-bg", id: "a1b2c3", state: "blocked"),
            // Its record didn't say so, but `claude agents` does.
            AgentEntry(cwd: "/p/app", kind: "background", pid: 78, sessionId: "unmarked", id: "u1", state: "working"),
            AgentEntry(cwd: "/p/app", kind: "background", startedAt: 3000, sessionId: "old-bg", name: "bump", id: "d4e5f6", state: "done"),
            AgentEntry(cwd: "/p/app", kind: "background", startedAt: 3000, sessionId: "old-bg", id: "dup", state: "done"),
            AgentEntry(cwd: "/p/gone", kind: "background", startedAt: 5000, sessionId: "no-file", id: "g1", state: "failed"),
            // No session id: nothing to open.
            AgentEntry(cwd: "/p/app", kind: "background", id: "nosess", state: "stopped"),
            // Running (a pid) but its record hasn't been read yet: it shows up with the record.
            AgentEntry(cwd: "/p/app", kind: "background", pid: 90, sessionId: "starting", id: "s1", state: "working"),
        ]
        var liveBg = bgSession("live-bg", pid: 77, jobId: nil)
        liveBg.isBackground = false
        let live = [session("tty"), liveBg, session("unmarked", pid: 78), session("plain", pid: 3)]
        let (merged, exited, updates) = BackgroundAgents.merge(live: live, agents: agents, cache: [:])
        expectEqual(merged.map(\.sessionId), ["tty", "live-bg", "unmarked", "plain"])
        expect(!merged[0].isBackground)
        expect(merged[1].isBackground)
        expectEqual(merged[1].jobId, "a1b2c3")
        expectEqual(merged[1].agentState, .blocked)
        expect(merged[2].isBackground)
        expectEqual(merged[2].jobId, "u1")
        expect(!merged[3].isBackground)
        // Newest first; each once.
        expectEqual(exited.map(\.sessionId), ["old-bg", "no-file"])
        let old = exited[0]
        expect(old.isBackground && !old.isLive && !old.canDrive)
        expectEqual(old.status, .ended)
        expectEqual(old.jobId, "d4e5f6")
        expectEqual(old.agentState, .done)
        expectEqual(old.title, "Bump the SDK")
        expectEqual(old.displayTitle, "Bump the SDK")
        expect(old.transcriptURL != nil, "its conversation opens, read-only")
        // Its title is cached, so the next look doesn't read the transcript again.
        expectEqual(updates[old.transcriptURL!.path]?.title, "Bump the SDK")
        let again = BackgroundAgents.merge(live: live, agents: agents, cache: updates)
        expect(again.updates.isEmpty)
        expectEqual(again.exited[0].title, "Bump the SDK")
        expectEqual(old.startedAt, Date(timeIntervalSince1970: 3))
        let gone = exited[1]
        expect(gone.transcriptURL == nil)
        expectEqual(gone.updatedAt, Date(timeIntervalSince1970: 5))
        expectEqual(gone.agentState, .failed)
        // No job id in the list: the record's is kept.
        // Opened from Deck: drivable through that window, while it runs.
        let opened = BackgroundAgents.merge(live: live, agents: agents, cache: [:], attached: ["live-bg", "tty"]).live
        expect(opened[1].attached && opened[1].canDrive)
        expect(!opened[0].attached, "only a background session is attached")
        expect(!opened[2].attached)
        let kept = BackgroundAgents.merge(live: [bgSession("r", jobId: "rec")], agents: [AgentEntry(cwd: "/p/app", kind: "background", pid: 1, sessionId: "r")], cache: [:])
        expectEqual(kept.live[0].jobId, "rec")
        // A started time unknown and no transcript: last in the list.
        let bare = BackgroundAgents.merge(live: [], agents: [AgentEntry(cwd: "/x", kind: "background", sessionId: "b", state: "done")], cache: [:])
        expectEqual(bare.exited.first?.updatedAt, .distantPast)
    }

    test("fleet news from background state changes: done finished, failed ended, blocked waiting") {
        func bg(_ id: String, _ state: AgentState?, live: Bool = true) -> Session {
            var s = bgSession(id, status: live ? .idle : .ended, pid: live ? 1 : nil, name: id)
            s.agentState = state
            return s
        }
        let before = [bg("a", .working), bg("b", .working), bg("c", .working), bg("d", .working), bg("e", .done),
                      bg("muted", .working), bg("f", .blocked), bg("g", nil)]
        let old = BackgroundAgents.states(before)
        expectEqual(old.count, 7)
        expectEqual(BackgroundAgents.states([bg("x", .done), bg("x", .failed)]), ["x": .done])
        let after = [bg("a", .done, live: false), bg("b", .failed, live: false), bg("c", .blocked), bg("d", .stopped, live: false),
                     bg("e", .done), bg("muted", .done), bg("f", .working), bg("g", .done), bg("new", .done)]
        expectEqual(BackgroundAgents.events(from: nil, to: after), [])
        let events = BackgroundAgents.events(from: old, to: after, excluded: ["muted"])
        let now = Date()
        expectEqual(events.map { FleetDigest.phrase($0, now: now) }, ["a finished", "b ended unexpectedly", "c waiting on you"])
        // Still true later: an exited job that's done (or failed) stays news, a blocked one only while blocked.
        var unblocked = bg("c", .working)
        unblocked.status = .busy
        let current = FleetDigest.current(events, live: [bg("a", .done, live: false), bg("b", .failed, live: false), unblocked],
                                          now: now, threshold: 600)
        expectEqual(current.map { FleetDigest.phrase($0, now: now) }, ["a finished", "b ended unexpectedly"])
        let blocked = FleetDigest.current([.waiting(bg("c", .blocked))], live: [bg("c", .blocked)], now: now, threshold: 600)
        expectEqual(blocked.count, 1)
        // A session that's running again isn't ended.
        expectEqual(FleetDigest.current([.ended(bg("b", .failed), unexpected: true)], live: [bg("b", .working)], now: now, threshold: 600), [])
    }
}
