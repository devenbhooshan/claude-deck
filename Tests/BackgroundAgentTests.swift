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
        expect(TerminalMatch.find(for: bgSession("bg"), in: only, preferred: "T1") == nil)
        var tty = bgSession("tty", status: .idle)
        tty.isBackground = false
        expectEqual(TerminalMatch.find(for: tty, in: only)?.id, "T1")
    }
}
