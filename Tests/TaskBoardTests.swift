import Foundation

private func json(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
private func item(_ title: String, _ state: TaskItem.State) -> TaskItem { TaskItem(state: state, title: title, session: nil, note: nil) }

func taskBoardTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    test("board edits: one line each, and what the task shows meanwhile") {
        func e(_ a: BoardEdit.Action, _ task: String = "Send invoice") -> BoardEdit { BoardEdit(task: task, action: a, at: t0) }
        expectEqual(e(.didIt).line, "Board: “Send invoice” → done (I did it)")
        expectEqual(e(.answer("Postgres,\n  not MySQL"), "Pick DB").line, "Board: “Pick DB” → answer: Postgres, not MySQL")
        expectEqual(e(.done).line, "Board: “Send invoice” → done")
        expectEqual(e(.unblock).what, "unblocked")
        expectEqual(e(.later).what, "move to later")
        expectEqual(e(.snooze(hours: 1)).what, "snoozed for an hour")
        expectEqual(e(.snooze(hours: 3)).what, "snoozed for 3 hours")
        expectEqual(e(.snooze(hours: 24)).what, "snoozed for a day")
        expectEqual(e(.snooze(hours: 48)).what, "snoozed for 2 days")
        expectEqual(e(.didIt).pendingLabel, "Sent: done")
        expectEqual(e(.answer("x")).pendingLabel, "Sent: your answer")
        expectEqual(e(.unblock).pendingLabel, "Sent: unblocked")
        expectEqual(BoardEdit.key("  Send   INVOICE "), "send invoice")
        expectEqual(e(.done, "A  b").id, "a b\u{1}1800000000.0")
        expect(e(.done).isReflected(by: .done) && !e(.done).isReflected(by: .doing) && e(.done).isReflected(by: nil))
        expect(e(.didIt).isReflected(by: .doing) && !e(.didIt).isReflected(by: .you))
        expect(e(.answer("a")).isReflected(by: .blocked) && !e(.answer("a")).isReflected(by: .you))
        expect(e(.unblock).isReflected(by: .todo) && !e(.unblock).isReflected(by: .blocked))
        expect(e(.later).isReflected(by: .todo) && e(.later).isReflected(by: .done) && !e(.later).isReflected(by: .doing))
        expect(e(.snooze(hours: 1)).isReflected(by: .you))
    }

    test("receipts: handoffs in one sentence, then a line per board change") {
        let h = Receipt.handoff(Handoff(target: "api", text: "go"))
        let b = Receipt.board(BoardEdit(task: "Pick DB", action: .answer("Postgres"), at: t0))
        let d = Receipt.board(BoardEdit(task: "Send invoice", action: .didIt, at: t0))
        expectEqual(Receipt.text(for: [h]), "[Claude Deck] I sent your message to api: “go”. No need to reply.")
        expectEqual(Receipt.text(for: [b, h, d]), """
        [Claude Deck] I sent your message to api: “go”. No need to reply.
        [Claude Deck] I changed your task board. Show this in your next board:
        Board: “Pick DB” → answer: Postgres
        Board: “Send invoice” → done (I did it)
        """)
        expectEqual(Receipt.quote(String(repeating: "a", count: 81)), "“" + String(repeating: "a", count: 79) + "…”")
    }

    test("pending changes clear once a newer board reflects them; snoozes end") {
        var s = BoardState()
        s.record(BoardEdit(task: "Send invoice", action: .didIt, at: t0))
        s.record(BoardEdit(task: "Pick DB", action: .answer("Postgres"), at: t0))
        s.record(BoardEdit(task: "Docs", action: .snooze(hours: 1), at: t0))
        expectEqual(s.edits.count, 2)
        expectEqual(s.pending(item("send  invoice", .you))?.action, .didIt)
        expect(s.pending(item("Other", .you)) == nil)
        expect(s.isSnoozed(item("docs", .blocked), now: t0.addingTimeInterval(3599)))
        expect(!s.isSnoozed(item("docs", .blocked), now: t0.addingTimeInterval(3601)))
        expect(!s.isSnoozed(item("Other", .todo), now: t0))

        expectEqual(s.reconciled(with: nil, now: t0).edits.count, 2)
        // An older board (the one you edited) changes nothing.
        let old = TaskBoard(items: [item("Send invoice", .you), item("Pick DB", .you)], at: t0.addingTimeInterval(-60))
        expectEqual(s.reconciled(with: old, now: t0), s)
        // A newer one that shows one of them: the other stays sent.
        let newer = TaskBoard(items: [item("Send invoice", .done), item("Pick DB", .you)], at: t0.addingTimeInterval(60))
        expectEqual(s.reconciled(with: newer, now: t0).edits.map(\.task), ["Pick DB"])
        // Gone from the board counts as shown; snoozes past their end are dropped.
        let gone = TaskBoard(items: [], at: t0.addingTimeInterval(60))
        let later = s.reconciled(with: gone, now: t0.addingTimeInterval(7200))
        expect(later.edits.isEmpty && later.snoozed.isEmpty)
        // A board that still disagrees long after: the coordinator's board wins.
        let stubborn = TaskBoard(items: [item("Send invoice", .you), item("Pick DB", .you)], at: t0.addingTimeInterval(BoardState.patience + 1))
        expect(s.reconciled(with: stubborn, now: t0).edits.isEmpty)
    }

    test("board state and decisions: saved per coordinator") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-board-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        BoardState.dir = root.appendingPathComponent("board")
        Decisions.dir = root.appendingPathComponent("decisions")
        expectEqual(BoardState.load("c1"), BoardState())
        var s = BoardState()
        s.record(BoardEdit(task: "Pick DB", action: .answer("Postgres"), at: t0))
        s.record(BoardEdit(task: "Docs", action: .snooze(hours: 24), at: t0))
        s.compactionSeen = "u1"
        s.save("c1")
        expectEqual(BoardState.load("c1"), s)
        expectEqual(BoardState.fileURL("a/b").lastPathComponent, "a_b.json")
        // The shape scripts/screenshots.py writes for its demo coordinator.
        let demo = #"{"edits":[{"task":"T","action":{"answer":{"_0":"A"}},"at":0},{"task":"U","action":{"unblock":{}},"at":0}],"snoozed":{}}"#
        expectEqual(try JSONDecoder().decode(BoardState.self, from: Data(demo.utf8)).edits.map(\.action), [.answer("A"), .unblock])

        expectEqual(Decisions.load("c1"), [])
        expect(Decisions.recap([]) == nil)
        Decisions.append(Decision(date: "2026-11-18", task: "Pick DB", answer: "Postgres"), to: "c1")
        Decisions.append(Decision(date: "2026-11-19", task: "Name “it”", answer: "Orbit:  v2\nfinal"), to: "c1")
        let text = try String(contentsOf: Decisions.fileURL("c1"), encoding: .utf8)
        expect(text.hasPrefix(Decisions.header))
        expect(text.hasSuffix("- 2026-11-18 “Pick DB”: Postgres\n- 2026-11-19 “Name “it””: Orbit: v2 final\n"))
        expectEqual(Decisions.load("c1"), [Decision(date: "2026-11-18", task: "Pick DB", answer: "Postgres"),
                                           Decision(date: "2026-11-19", task: "Name “it”", answer: "Orbit: v2 final")])
        expectEqual(Decisions.recap(Decisions.load("c1")), """
        [Claude Deck] Decisions so far:
        - 2026-11-18 “Pick DB”: Postgres
        - 2026-11-19 “Name “it””: Orbit: v2 final
        """)
        expectEqual(Decisions.parse("# Decisions\n- not a decision\n- 2026-01-02 “T”: "), [Decision(date: "2026-01-02", task: "T", answer: "")])
        let noon = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 12))!
        expectEqual(Decisions.day(noon), "2026-03-04")
        expectEqual(Decisions.safeName("ab-C_1.x/"), "ab-C_1_x_")
    }

    test("compaction: the newest boundary, recapped once and never for old ones") {
        let lines = [
            json(["type": "system", "subtype": "compact_boundary", "uuid": "old", "content": "Conversation compacted"]),
            json(["type": "user", "isCompactSummary": true, "message": ["content": "made-up summary"]]),
            json(["type": "system", "subtype": "compact_boundary", "uuid": "side", "isSidechain": true]),
            json(["type": "assistant", "message": ["content": "talks about compact_boundary"]]),
            Data("{broken compact_boundary".utf8),
        ]
        expectEqual(Compaction.latest(in: lines), "old")
        expect(Compaction.latest(in: [json(["type": "user", "message": ["content": "x"]])]) == nil)
        expect(Compaction.latest(in: [json(["type": "system", "subtype": "compact_boundary"])]) == nil)

        // First look: remember what's there, say nothing.
        expect(BoardState.compaction(latest: "old", seen: nil) == (false, "old"))
        expect(BoardState.compaction(latest: nil, seen: nil) == (false, ""))
        expect(BoardState.compaction(latest: "old", seen: "old") == (false, "old"))
        expect(BoardState.compaction(latest: nil, seen: "old") == (false, "old"))
        expect(BoardState.compaction(latest: "new", seen: "old") == (true, "new"))
        expect(BoardState.compaction(latest: "first", seen: "") == (true, "first"))
    }
}
