import AppKit

private func doc(_ id: String, _ session: String, _ text: String, at: Double? = nil, kind: SearchDoc.Kind = .message) -> SearchDoc {
    SearchDoc(id: id, sessionId: session, kind: kind, at: at.map { Date(timeIntervalSince1970: $0) }, text: text)
}

func searchTests() {
    test("your messages are kept, cleaned, with where they are") {
        var x = ActivityExtractor(sessionId: "s")
        let lines: [(String, UInt64)] = [
            (#"{"type":"user","timestamp":"2026-10-15T05:00:00.000Z","message":{"content":"we need to do the <pasted_content id=\"1\">AppSumo</pasted_content> integration [Image #2]"}}"#, 100),
            (#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#, 200),
            (#"{"type":"user","message":{"content":[{"type":"text","text":"  "}]}}"#, 300),
            (#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"big"}]}}"#, 400),
        ]
        for (l, o) in lines { x.ingest(Data(l.utf8), offset: o) }
        expectEqual(x.asks.map(\.text), ["we need to do the AppSumo integration"])
        expectEqual(x.asks[0].offset, 100)
        expectEqual(x.asks[0].id, "s:m1")
        expect(ActivityAsk.clean("<task-notification>x</task-notification>") == nil)
        expect(ActivityAsk.clean("[Request interrupted by user]") == nil)
        expectEqual(ActivityAsk.clean(String(repeating: "a ", count: 400))?.count, ActivityAsk.maxLength + 1)
    }
    test("the index finds messages and events, and remembers offsets") {
        let box = Sandbox(); defer { box.cleanup() }
        let line = #"{"type":"user","timestamp":"2026-10-15T05:00:00.000Z","message":{"content":"start the appsumo plan"}}"#
        let pr = #"{"type":"assistant","timestamp":"2026-10-15T05:01:00.000Z","message":{"content":[{"type":"tool_use","id":"p","name":"Bash","input":{"command":"gh pr merge 3"}}]}}"#
        let title = #"{"type":"ai-title","aiTitle":"AppSumo plan"}"#
        let url = box.write("claude/projects/-w/33333333-3333-4333-8333-333333333333.jsonl", "{\"pad\":1}\n" + line + "\n" + pr + "\n" + title + "\n")
        _ = url
        var index: [String: SessionActivity] = [:]
        _ = ActivityIndex.refresh(&index)
        let docs = SearchIndex.documents(from: Array(index.values))
        expectEqual(docs.map(\.kind), [.message, .event(.mergedPR), .session])
        expectEqual(docs[0].offset, 10)
        expectEqual(docs[2].text, "AppSumo plan")
        let none = SearchIndex.documents(from: [SessionActivity(extractor: ActivityExtractor(sessionId: "e"), path: "/x")])
        expect(none.isEmpty)
        let task = ActivityEvent(id: "e:task1", sessionId: "e", kind: .startedTask, title: "LTD launch", offset: 42)
        let withTask = SearchIndex.documents(from: [], extra: [task])
        expectEqual(withTask.first?.text, "Started task · LTD launch")
        expectEqual(withTask.first?.offset, 42)
        var titled = ActivityExtractor(sessionId: "t")
        titled.ingest(Data(#"{"type":"ai-title","aiTitle":"Only a title","timestamp":"2026-10-15T05:00:00.000Z"}"#.utf8))
        let onlyTitle = SearchIndex.documents(from: [SessionActivity(extractor: titled, path: "/x")])
        expectEqual(onlyTitle.first?.at, Rx.date("2026-10-15T05:00:00.000Z"))
    }
    test("ranking: rare words, prefixes while typing, typos, phrases, dates") {
        let si = SearchIndex(docs: [
            doc("a", "s1", "lets build the rails integration", at: 10),
            doc("b", "s2", "we need to do the appsumo integration now", at: 50),
            doc("c", "s2", "appsumo partner portal tiers", at: 60),
            doc("d", "s3", "integrations everywhere integrations", at: 70),
            doc("e", "s3", "lifetime deal plan for appsumo", at: 80),
        ])
        expect(si.search(["the of"]).isEmpty, "only stopwords")
        expectEqual(si.search(["appsumo"]).map(\.doc.id).sorted(), ["b", "c", "e"])
        expectEqual(si.search(["apsumo"]).map(\.doc.id).sorted(), ["b", "c", "e"])            // one typo
        expectEqual(si.search(["integratoins"]).first?.doc.id.isEmpty, false)                   // swapped letters, long word
        expect(si.search(["xyz"]).isEmpty)
        expect(si.search(["ab"]).isEmpty, "too short to guess")
        expectEqual(si.search(["appsu"], prefix: true).count, 3)
        expectEqual(si.search(["appsumo integration"]).first?.doc.id, "b")
        expectEqual(si.search(["lifetime deal"]).first?.doc.id, "e")
        let log = SearchIndex(docs: [doc("m", "s", "Merged PR #4"), doc("p", "s", "Pushed main"), doc("x", "s", "lunch")])
        expectEqual(log.search(["what shipped"]).map(\.doc.id).sorted(), ["m", "p"])
        expectEqual(si.search(["appsumo"], since: Date(timeIntervalSince1970: 55)).map(\.doc.id).sorted(), ["c", "e"])
        expect(SearchIndex(docs: [doc("u", "s", "appsumo")]).search(["appsumo"], since: Date(timeIntervalSince1970: 1)).isEmpty)
        let topical = si.search(["integration", "plan"], topic: ["appsumo"])
        expectEqual(topical.first { $0.doc.id == "a" }?.matched, 0)
        expectEqual(topical.first { $0.doc.id == "b" }?.matched, 1)
        expectEqual(SearchIndex.tokens("Integrations, the Plans!"), ["integration", "plan"])
        expectEqual(SearchIndex.stem("class"), "class")
        expectEqual(SearchIndex.distance("", "ab", limit: 2), 2)
        expectEqual(SearchIndex.distance("abcd", "wxyz", limit: 1), 2)
        expectEqual(SearchIndex.distance("ab", "ba", limit: 1), 1)
        let empty = SearchIndex(docs: [])
        expect(empty.search(["anything"]).isEmpty)
    }
    test("sessions: the first time, the latest, or the best match") {
        let si = SearchIndex(docs: [
            doc("a", "old", "lets build the rails integration", at: 10),
            doc("b", "new", "we need to do the appsumo integration", at: 50),
            doc("c", "new", "appsumo integration tiers", at: 60),
            doc("d", "later", "appsumo integration follow up", at: 90),
            doc("e", "undated", "appsumo integration", at: nil),
        ])
        let (terms, order, _) = SessionSearch.plain("on which session I started working on apppsumo integration")
        expectEqual(order, .first)
        let first = SessionSearch.sessions(si.search(terms), order: order)
        expectEqual(first.map(\.sessionId), ["new", "later", "undated"])     // the rails one only half-matches
        expectEqual(first[0].hits.map(\.doc.id), ["b", "c"])
        expectEqual(first[0].first, Date(timeIntervalSince1970: 50))
        expectEqual(first[0].last, Date(timeIntervalSince1970: 60))
        expectEqual(SessionSearch.plain("latest appsumo work").order, .latest)
        let latest = SessionSearch.sessions(si.search(["appsumo integration"]), order: .latest)
        expectEqual(latest.first?.sessionId, "later")
        expectEqual(latest.first?.hits.first?.doc.id, "d")
        expectEqual(SessionSearch.plain("appsumo").order, .all)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 86_400 * 10 + 43_200)
        let shipped = SessionSearch.plain("what shipped today", now: noon, calendar: utc)
        expectEqual(shipped.since, Date(timeIntervalSince1970: 86_400 * 10))
        expect(!shipped.terms[0].contains("today") && shipped.terms[0].contains("shipped"))
        expectEqual(shipped.order, .all)
        let week = SessionSearch.plain("PRs merged last week or yesterday", now: noon, calendar: utc)
        expectEqual(week.since, Date(timeIntervalSince1970: 86_400 * 3))
        expectEqual(week.order, .all)                                  // "last week" is a time, not "the latest"
        expectEqual(SessionSearch.plain("the last appsumo change").order, .latest)
        let all = SessionSearch.sessions(si.search(["appsumo integration"]), order: .all)
        expectEqual(Set(all.map(\.sessionId)), ["new", "later", "undated"])
        expect(SessionSearch.sessions([], order: .all).isEmpty)
        // Ties are broken by session, so the order never flickers.
        let tie = SessionSearch.sessions([SearchHit(doc: doc("x", "b", "t", at: 5), score: 1), SearchHit(doc: doc("y", "a", "t", at: 5), score: 1)], order: .latest)
        expectEqual(tie.map(\.sessionId), ["a", "b"])
        let tieAll = SessionSearch.sessions([SearchHit(doc: doc("x", "b", "t"), score: 1), SearchHit(doc: doc("y", "a", "t"), score: 1)], order: .all)
        expectEqual(tieAll.map(\.sessionId), ["a", "b"])
        for order in [SessionSearch.Order.first, .latest] {
            let two = [SearchHit(doc: doc("u", "undated", "t"), score: 1), SearchHit(doc: doc("d", "dated", "t", at: 4), score: 1)]
            expectEqual(SessionSearch.sessions(two, order: order).map(\.sessionId), ["dated", "undated"])
            expectEqual(SessionSearch.sessions(two.reversed(), order: order).map(\.sessionId), ["dated", "undated"])
        }
        let mixed = [SearchHit(doc: doc("x", "b", "t"), score: 1), SearchHit(doc: doc("y", "b", "t", at: 3), score: 1),
                     SearchHit(doc: doc("z", "b", "t"), score: 1), SearchHit(doc: doc("w", "b", "t", at: 1), score: 1)]
        let undatedFirst = SessionSearch.sessions(mixed, order: .first)
        expectEqual(Array(undatedFirst[0].hits.map(\.doc.id).prefix(2)), ["w", "y"])
        let undatedLatest = SessionSearch.sessions(mixed.reversed(), order: .latest)
        expectEqual(Array(undatedLatest[0].hits.map(\.doc.id).prefix(2)), ["y", "w"])
    }
    test("asking Haiku: the question becomes a search, the answer names moments") {
        let q = SessionSearch.intentPrompt("when did I start appsumo")
        expect(q.contains("Question: when did I start appsumo"))
        let intent = SessionSearch.parseIntent(#"{"structured_output":{"topic":["appsumo"," "],"related":["lifetime deal"],"order":"first","since_days":7}}"#)
        expectEqual(intent, SessionSearch.Intent(topic: ["appsumo"], related: ["lifetime deal"], order: .first, sinceDays: 7))
        expectEqual(SessionSearch.parseIntent(#"{"structured_output":{"topic":["x"],"order":"all","since_days":0}}"#)?.sinceDays, nil)
        expect(SessionSearch.parseIntent(#"{"structured_output":{"topic":[],"order":"all"}}"#) == nil)
        expect(SessionSearch.parseIntent(#"{"structured_output":{"topic":["x"],"order":"sometimes"}}"#) == nil)
        expect(SessionSearch.parseIntent("nope") == nil)

        let hits = [SessionHit(sessionId: "s1", hits: [SearchHit(doc: doc("m1", "s1", "start appsumo", at: 5), score: 2),
                                                      SearchHit(doc: doc("m2", "s1", "undated"), score: 1)], first: nil, last: nil, score: 2)]
        for order in [SessionSearch.Order.first, .latest, .all] {
            let p = SessionSearch.answerPrompt("when?", order: order, sessions: hits, title: { "T-\($0)" })
            expect(p.contains("\"session\":\"T-s1\"") && p.contains("\"time\":\"unknown\""))
        }
        let utc = SessionSearch.answerPrompt("when?", order: .first, sessions: hits, title: { $0 }, timeZone: TimeZone(identifier: "UTC")!)
        expect(utc.contains("Thu, Jan 1 1970, 12:00 AM"))
        let ok = #"{"structured_output":{"answer":" In T-s1, Oct 15. ","picks":[{"id":"m1","why":"you started it"},{"id":"zz","why":"x"},{"why":"no id"},{"id":"m2"}]}}"#
        let a = SessionSearch.parseAnswer(ok, ids: ["m1", "m2"])!
        expectEqual(a.answer, "In T-s1, Oct 15.")
        expectEqual(a.picks.map(\.id), ["m1", "m2"])
        expectEqual(a.picks[1].why, "")
        expect(SessionSearch.parseAnswer(#"{"structured_output":{"answer":"  ","picks":[]}}"#, ids: []) == nil)
        expectEqual(SessionSearch.parseAnswer(#"{"structured_output":{"answer":"No."}}"#, ids: [])?.picks.count, 0)
    }
    test("opening a session at an old message: the window around it, and pointing it out") {
        let box = Sandbox(); defer { box.cleanup() }
        let lines = (0..<50).map { #"{"type":"user","message":{"content":"message number \#($0)"}}"# }
        let text = lines.joined(separator: "\n") + "\n"
        let url = box.write("t.jsonl", text)
        let offset = UInt64(text.utf8.count / 2)
        let window = TailReader.window(url, around: offset, before: 300, after: 600)
        expect(!window.isEmpty && window.count < 50)
        expect(window.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil }, "only whole lines")
        expectEqual(TailReader.window(url, around: 0, before: 300, after: 100_000).count, 50)
        expect(TailReader.window(box.root.appendingPathComponent("missing"), around: 0).isEmpty)
        expect(TailReader.window(url, around: 50_000_000, before: 10, after: 10).isEmpty)
        let partial = box.write("p.jsonl", lines[0] + "\n" + lines[1])
        expectEqual(TailReader.window(partial, around: 0).count, 1)

        let parser = TranscriptParser(url: url)
        parser.loadWindow(around: offset)
        expectEqual(parser.items.count, 50)  // the default window covers this small file

        expectEqual(TranscriptTextController.range(of: "Message   number 7", in: "x\nmessage\nnumber 7 y")?.location, 2)
        expect(TranscriptTextController.range(of: "   ", in: "abc") == nil)
        expect(TranscriptTextController.range(of: "nowhere", in: "abc") == nil)

        let ctl = TranscriptTextController(openURL: { _ in true })
        let scroll = ctl.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        scroll.tile()
        let items = (0..<60).map { item(.user("line \($0) of the old conversation", images: []), "u\($0)") }
        var c = TranscriptContent(blocks: items.map { .item($0) }, results: [:], queued: [], outgoing: [], cwd: "/",
                                  status: .idle, openToolId: nil, loaded: true)
        c.focus = "line 3 of the old conversation"
        ctl.content = c
        ctl.render(force: true)
        let visible = scroll.contentView.bounds
        expect(visible.minY < ctl.textView!.frame.height / 2, "scrolled up to the message")
        ctl.render(force: true)   // pointed out once
        // Back to Latest: the same view, no focus, goes to the bottom again.
        c.focus = nil
        ctl.content = c
        ctl.render(force: true)
        expect(scroll.contentView.bounds.maxY >= ctl.textView!.frame.height - 1, "back at the bottom")
    }
}
