import Foundation

private func line(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
private func session(_ name: String, live: Bool = true, status: SessionStatus = .idle, id: String? = nil) -> Session {
    Session(sessionId: id ?? name, pid: live ? 1 : nil, cwd: "/tmp/\(name)", name: name, title: nil, status: status,
            waitingFor: nil, updatedAt: Date(), transcriptURL: nil)
}

func coordinationTests() {
    test("new-session cards: name, optional folder, first message, safety") {
        expectEqual(Handoff.from(info: "new-session taxes ~/worksplace/ai-workspace", code: "\n Do my ITR \n"),
                    Handoff(target: "taxes", text: "Do my ITR", newSession: true, folder: "~/worksplace/ai-workspace"))
        expectEqual(Handoff.from(info: "New-Session tax filing /tmp", code: "go")?.target, "tax filing")
        expectEqual(Handoff.from(info: "new-session tax filing", code: "go")?.folder, nil)
        expectEqual(Handoff.from(info: "new-session ~/x", code: "go")?.target, "~/x")
        expect(Handoff.from(info: "new-session", code: "go") == nil)
        expect(Handoff.from(info: "swift", code: "go") == nil)
        expect(Handoff.from(info: nil, code: "go") == nil)
        expect(Handoff.from(info: "new-session a", code: "  ") == nil)
        expect(Handoff.isCard(info: "new-session a") && Handoff.isCard(info: "send-to b") && !Handoff.isCard(info: "tasks"))
        expect(!Handoff(target: "a", text: "-p hi", newSession: true).isTypeable)
        expect(Handoff(target: "a", text: "-p hi").isTypeable)
        expectEqual(Handoff(target: "A", text: "go", newSession: true).key, "new\u{1}a\u{1}go")
        let h = Handoff(target: "a", text: "go", newSession: true, folder: "~/w")
        expectEqual(h.startFolder(home: "/Users/me", fallback: "/f"), "/Users/me/w")
        expectEqual(Handoff(target: "a", text: "go", newSession: true, folder: "~").startFolder(home: "/Users/me", fallback: "/f"), "/Users/me")
        expectEqual(Handoff(target: "a", text: "go", newSession: true, folder: "/abs").startFolder(fallback: "/f"), "/abs")
        expectEqual(Handoff(target: "a", text: "go", newSession: true).startFolder(fallback: "/f"), "/f")
        expectEqual(Handoff.all(in: "```new-session taxes\nbrief\n```\n\n```send-to cos\nhi\n```").map(\.newSession), [true, false])
    }

    test("task board lines: state words, session, note") {
        let t = TaskItem.parse(line: "- [doing] Rotate encryption keys @supergrow — testing the rake task")
        expectEqual(t, TaskItem(state: .doing, title: "Rotate encryption keys", session: "supergrow", note: "testing the rake task"))
        expectEqual(TaskItem.parse(line: "* [x] Ship @nook @site -- live")?.session, "site")
        expectEqual(TaskItem.parse(line: "* [x] Ship @nook @site -- live")?.title, "Ship @nook")
        expectEqual(TaskItem.parse(line: "- [ ] Write spec")?.state, .todo)
        expect(TaskItem.parse(line: "- [ ] Write spec")?.session == nil)
        expect(TaskItem.parse(line: "- [you] Approve deploy — ")?.note == nil)
        expect(TaskItem.parse(line: "plain text") == nil)
        expect(TaskItem.parse(line: "- [doing] @only") == nil)
        expect(TaskItem.parse(line: "- [doing] Thing @")?.session == nil)
        for (word, state) in [("Needs You", TaskItem.State.you), ("waiting", .you), ("ask", .you), ("blocked", .blocked),
                              ("stuck", .blocked), ("working", .doing), ("in progress", .doing), ("wip", .doing), ("~", .doing),
                              ("done", .done), ("X", .done), ("shipped", .done), ("todo", .todo), ("later", .todo)] {
            expectEqual(TaskItem.State.parse(word), state)
        }
        expectEqual(TaskItem.State.allCases.map(\.label), ["Needs you", "Blocked", "In progress", "To do", "Done"])
        expectEqual(TaskItem(state: .todo, title: "a", session: "b", note: nil).id, "a\u{1}b")
        expectEqual(TaskItem(state: .todo, title: "a", session: nil, note: nil).id, "a\u{1}")
    }

    test("task board: the newest tasks block from the main conversation") {
        let reply = """
        Status:

        ```tasks
        - [doing] Keys @api
        - [done] JWKS
        not a task
        ```

        > ```tasks
        > - [todo] quoted
        > ```

        ```tasks
        - [you] Approve @api
        - [doing] Spec
        - [doing] Site
        ```
        """
        expectEqual(TaskBoard.items(in: reply)?.map(\.title), ["Approve", "Spec", "Site"])
        expect(TaskBoard.items(in: "```swift\nx\n```") == nil)
        let at = "2026-11-10T10:00:00.000Z"
        func msg(_ text: String, type: String = "assistant", side: Bool = false, ts: String? = at) -> Data {
            var o: [String: Any] = ["type": type, "isSidechain": side,
                                    "message": ["content": [["type": "text", "text": text], ["type": "tool_use", "name": "x"]]]]
            if let ts { o["timestamp"] = ts }
            return line(o)
        }
        let board = TaskBoard.latest(in: [
            msg("```tasks\n- [todo] Old\n```"),
            msg("```tasks\n- [doing] New\n- [done] A\n- [doing] B\n```"),
            msg("```tasks\n- [todo] Agent\n```", side: true),
            msg("```tasks\n- [todo] Mine\n```", type: "user"),
            msg("```tasks\n- [todo] No time\n```", ts: nil),
            msg("mentions ```tasks inline"),
            Data("```tasks broken".utf8),
            msg("no board"),
        ])
        expectEqual(board?.items.map(\.title), ["New", "A", "B"])
        expectEqual(board?.at, ISO8601DateFormatter.withFractions.date(from: at))
        expectEqual(board?.counts.map(\.0), [.doing, .done])
        expectEqual(board?.counts.map(\.1), [2, 1])
        expect(TaskBoard.latest(in: [msg("nothing")]) == nil)
        expect(TaskBoard.request.contains("```") == false && TaskBoard.request.contains("tasks"))
        expect(TaskBoard.ask(about: TaskItem(state: .you, title: "Radar", session: nil, note: nil)).contains("“Radar”"))
    }

    test("handoff blocks: target from the info string, text, safety") {
        expectEqual(Handoff.target(info: "send-to supergrow"), "supergrow")
        expectEqual(Handoff.target(info: " Send-To  chief of staff "), "chief of staff")
        expect(Handoff.target(info: nil) == nil)
        expect(Handoff.target(info: "swift") == nil)
        expect(Handoff.target(info: "send-to") == nil)
        let reply = """
        Paste this:

        ```send-to supergrow
        Merge #234
        ```

        ```swift
        let x = 1
        ```

        > ```send-to nook
        > quoted
        > ```

        ```send-to nook
           
        ```
        """
        expectEqual(Handoff.all(in: reply), [Handoff(target: "supergrow", text: "Merge #234")])
        expect(Handoff(target: "a", text: "go").isTypeable)
        expect(!Handoff(target: "a", text: "/exit").isTypeable)
        expect(!Handoff(target: "a", text: "!rm x").isTypeable)
        expectEqual(Handoff(target: "Nook", text: "hi").key, "nook\u{1}hi")
        expectEqual(Handoff.receipt(for: [Handoff(target: "supergrow", text: "Merge\n  #234")]),
                    "[Claude Deck] I sent your message to supergrow: “Merge #234”. No need to reply.")
        let long = String(repeating: "a", count: 100)
        expectEqual(Handoff.receipt(for: [Handoff(target: "a", text: "x"), Handoff(target: "taxes", text: long, newSession: true)]),
                    "[Claude Deck] I sent your message to a: “x”; started the session taxes with your first message “\(String(repeating: "a", count: 79))…”. No need to reply.")
    }

    test("addressing a session with @name") {
        expectEqual(SessionAddress.token("Chief of  Staff"), "chief-of-staff")
        expect(SessionAddress.split("@supergrow  merge it ").map { [$0.name, $0.message] } == ["supergrow", "merge it"])
        expect(SessionAddress.split("@supergrow\nline two").map { $0.message } == "line two")
        expect(SessionAddress.split("hello @x y") == nil)
        expect(SessionAddress.split("@supergrow") == nil)
        expect(SessionAddress.split("@ hi") == nil)
        expect(SessionAddress.split("@x   ") == nil)
        let all = [session("chief of staff"), session("nook"), session("old", live: false), session("dup", id: "1"), session("dup", id: "2")]
        expectEqual(SessionAddress.resolve("chief-of-staff", in: all)?.sessionId, "chief of staff")
        expectEqual(SessionAddress.resolve("Nook", in: all)?.sessionId, "nook")
        expect(SessionAddress.resolve("old", in: all) == nil)
        expect(SessionAddress.resolve("dup", in: all) == nil)
        expectEqual(SessionAddress.query(in: "@sup"), "sup")
        expect(SessionAddress.query(in: "@sup x") == nil)
        expect(SessionAddress.query(in: "sup") == nil)
    }

    test("needs-you list: prompts, handoffs (coordinator first), questions") {
        var waiting = session("w", status: .waiting)
        waiting.pendingTool = nil
        var answered = session("a", status: .waiting)
        answered.pendingTool = nil
        var cos = session("cos")
        cos.handoffs = [Handoff(target: "w", text: "go"), Handoff(target: "w", text: "sent")]
        var other = session("other")
        other.handoffs = [Handoff(target: "w", text: "later"), Handoff(target: "w", text: "hidden")]
        var asker = session("asker")
        asker.replyTexts = ["Done.\n\nShould I merge it?\n\n  "]
        asker.replies = [Date(timeIntervalSince1970: 5)]
        var busyAsker = session("busy", status: .busy)
        busyAsker.replyTexts = ["Merge?"]
        var told = session("told")
        told.replyTexts = ["Done."]
        var gone = session("gone")
        gone.replyTexts = ["Ok?"]
        let items = Inbox.items(live: [waiting, answered, other, cos, asker, busyAsker, told, gone, session("quiet")],
                                sent: [Handoff(target: "w", text: "sent").key],
                                dismissed: [Handoff(target: "w", text: "hidden").key, Inbox.questionKey(gone)],
                                coordinator: "cos", isAnswered: { $0.sessionId == "a" })
        expectEqual(items.map(\.id), ["prompt:w", "handoff:cos:w\u{1}go", "handoff:other:w\u{1}later", "question:asker"])
        expectEqual(items.map(\.session.sessionId), ["w", "cos", "other", "asker"])
        expect(items.last == .question(asker, "Should I merge it?"))
        expectEqual(Inbox.questionKey(asker), "question:asker:5.0")
        expectEqual(Inbox.questionKey(session("none")), "question:none:0.0")
        var long = session("long")
        long.replyTexts = [String(repeating: "x", count: 500) + "?"]
        expectEqual(Inbox.question(in: long)?.count, 400)
        expect(Inbox.items(live: [waiting], sent: [], dismissed: []).count == 1)
    }

    test("messages between sessions, from transcripts") {
        let at = "2026-11-09T10:00:00.000Z"
        let send: [String: Any] = ["type": "tool_use", "name": "SendMessage", "input": ["to": "supergrow", "summary": "Status", "message": "How's it going?"]]
        let empty: [String: Any] = ["type": "tool_use", "name": "SendMessage", "input": ["to": "supergrow", "message": ""]]
        let lines = [
            line(["type": "assistant", "timestamp": at, "message": ["content": [["type": "text", "text": "x"], send, empty]]]),
            line(["type": "assistant", "timestamp": at, "isSidechain": true, "message": ["content": [send]]]),
            line(["type": "assistant", "timestamp": "bad", "message": ["content": [send]]]),
            line(["type": "user", "timestamp": at, "message": ["content": [["name": "SendMessage"]]]]),
            line(["type": "assistant", "timestamp": at, "message": ["content": "\"name\":\"SendMessage\""]]),
            Data(#"{"name":"SendMessage" broken"#.utf8),
            line(["type": "assistant", "timestamp": at, "message": ["content": [["type": "text", "text": "no send"]]]]),
        ]
        let sent = CommsMessage.sent(in: lines, by: "cos")
        expectEqual(sent.count, 1)
        expectEqual(sent.first?.summary, "Status")
        expectEqual(sent.first?.to, "supergrow")
        let t = ISO8601DateFormatter.withFractions.date(from: at)!
        let a = CommsMessage(from: "cos", to: "x", summary: nil, text: "1", at: t)
        let b = CommsMessage(from: "nook", to: "cos", summary: nil, text: "2", at: t.addingTimeInterval(60))
        let c = CommsMessage(from: "cos", to: "y", summary: nil, text: "3", at: t.addingTimeInterval(120))
        expectEqual(CommsMessage.merge([[a, c], [b, a]]), [c, b, a])
        expectEqual(CommsMessage.merge([[a, b, c]], limit: 2), [c, b])
        expectEqual(CommsMessage.latestBySender([a, b, c]), [c, b])
    }

    test("handoffs found in a session's replies, and fence info kept") {
        let reply = line(["type": "assistant", "timestamp": "2026-11-09T10:00:00.000Z",
                          "message": ["content": [["type": "text", "text": "Ready.\n\n```send-to supergrow\nmerge it\n```"]]]])
        expectEqual(SessionLoader.handoffs(in: [reply]), [Handoff(target: "supergrow", text: "merge it")])
        expectEqual(Markdown.parse("```swift\nx\n```").first?.info, "swift")
    }
}
