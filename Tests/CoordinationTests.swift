import Foundation

private func line(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
private func session(_ name: String, live: Bool = true, status: SessionStatus = .idle, id: String? = nil) -> Session {
    Session(sessionId: id ?? name, pid: live ? 1 : nil, cwd: "/tmp/\(name)", name: name, title: nil, status: status,
            waitingFor: nil, updatedAt: Date(), transcriptURL: nil)
}

func coordinationTests() {
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
