import Foundation

/// One transcript line, written the way Claude Code writes them (compact, slashes unescaped).
private func line(_ obj: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys])
}

private let t0 = "2026-10-15T05:00:00.000Z"

private func tool(_ id: String, _ name: String, _ input: [String: Any], branch: String = "main", at: String = t0) -> Data {
    line(["type": "assistant", "timestamp": at, "gitBranch": branch, "cwd": "/w/api",
          "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}

private func bash(_ id: String, _ command: String, branch: String = "main") -> Data {
    tool(id, "Bash", ["command": command], branch: branch)
}

private func result(_ id: String, _ content: Any = "ok", error: Bool = false) -> Data {
    var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
    if error { block["is_error"] = true }
    return line(["type": "user", "timestamp": t0, "message": ["content": [block]]])
}

private func say(_ text: String) -> Data {
    line(["type": "assistant", "timestamp": t0, "message": ["content": [["type": "text", "text": text]]]])
}

private func human(_ content: Any, meta: Bool = false) -> Data {
    var o: [String: Any] = ["type": "user", "timestamp": t0, "message": ["content": content]]
    if meta { o["isMeta"] = true }
    return line(o)
}

private func extract(_ lines: [Data]) -> ActivityExtractor {
    var x = ActivityExtractor(sessionId: "s1")
    for l in lines { x.ingest(l) }
    return x
}

func activityTests() {
    test("PR commands: opened, merged, reviewed, commented, looked at") {
        let x = extract([
            bash("c1", "cd ~/w/fe && gh pr create --title \"SUP-610: Approval flow\" --body \"$(cat <<'EOF'\nFixes 2 bugs; gh pr merge 9\nEOF\n)\""),
            result("c1", "https://github.com/acme/fe/pull/41\n"),
            say("Opened the PR for the approval flow."),
            bash("c2", "gh pr review 41 --approve"),
            result("c2"),
            bash("c3", "R=acme/api; gh pr view 7 -R $R && gh pr merge 7 -R ${R} --squash && gh pr view 7 -R $R --json state"),
            result("c3", [["type": "text", "text": "Merged"]]),
            bash("c4", "gh pr comment 8 --repo acme/api --body hi"),
            result("c4"),
            bash("c5", "gh api repos/acme/api/pulls/9/reviews -X POST -f event=COMMENT"),
            result("c5"),
            bash("c6", "gh api repos/acme/api/pulls/9/comments --input body.json"),
            result("c6"),
            bash("c7", "gh api repos/acme/api/pulls/9"),               // a read: not an event
            bash("c8", "grep -n 'gh pr merge 5' notes.txt"),          // only mentions it
        ])
        let e = x.events
        expectEqual(e.map(\.kind), [.openedPR, .reviewedPR, .mergedPR, .commentedPR, .reviewedPR, .commentedPR])
        expectEqual(e[0].number, 41)
        expectEqual(e[0].repo, "acme/fe")
        expectEqual(e[0].title, "SUP-610: Approval flow")
        expectEqual(e[0].url, "https://github.com/acme/fe/pull/41")
        expectEqual(e[0].dir, NSString(string: "~/w/fe").expandingTildeInPath)
        expectEqual(e[0].quote, "Opened the PR for the approval flow.")
        expectEqual(e[1].detail, "Approved")
        expectEqual(e[1].dir, NSString(string: "~/w/fe").expandingTildeInPath)  // the shell stays where it was
        expectEqual(e[2].repo, "acme/api")
        expectEqual(e[2].url, "https://github.com/acme/api/pull/7")
        expectEqual(e[3].repo, "acme/api")
        expectEqual(e[4].number, 9)
        expectEqual(x.cwd, "/w/api")
    }
    test("review details, PR of the branch, failed commands, repeats") {
        let x = extract([
            line(["type": "pr-link", "prNumber": 12, "prRepository": "acme/api", "prUrl": "https://github.com/acme/api/pull/12", "timestamp": t0, "gitBranch": "deven/sup-7-x"]),
            line(["type": "pr-link", "prNumber": 12, "prRepository": "acme/api", "timestamp": t0]),          // again: ignored
            line(["type": "pr-link", "prRepository": "acme/api"]),                                             // no number
            bash("a", "gh pr view --json title", branch: "deven/sup-7-x"),   // branch's PR, already linked → no repeat
            bash("b", "gh pr review --request-changes -b fix", branch: "deven/sup-7-x"),
            result("b"),
            bash("c", "gh pr merge 30"),
            result("c", "not mergeable", error: true),
            bash("d", "gh pr review 31 --comment -b hm"),
            result("d"),
            bash("e", "gh pr diff 31"),                                        // already reviewed: not news
            bash("f", "gh pr view"),                                           // no number, branch has no PR here
            bash("g", "gh pr create --title 'One'"),
            result("g", "no url here"),
        ])
        let kinds = x.events.map(\.kind)
        expectEqual(kinds, [.reviewedPR, .reviewedPR, .openedPR])  // the link gives way to the review; the failed merge is dropped
        expectEqual(x.events[0].number, 12)
        expectEqual(x.events[0].repo, "acme/api")
        expectEqual(x.events[0].detail, "Requested changes")
        expectEqual(x.events[1].detail, "Commented")
        expect(x.events[2].number == nil && x.events[2].title == "One")
        expectEqual(x.branch, "main")
    }
    test("tickets: Linear tools, links you paste, results fill titles") {
        let issue = #"{"id":"SUP-645","title":"Org analytics","url":"https://linear.app/s/issue/SUP-645/org"}"#
        let x = extract([
            tool("l1", "mcp__claude_ai_Linear__get_issue", ["id": "sup-645"]),
            result("l1", [["type": "text", "text": issue]]),
            tool("l2", "mcp__claude_ai_Linear__get_issue", ["id": "SUP-645"]),     // seen: not news
            tool("l3", "mcp__claude_ai_Linear__save_issue", ["title": "New thing"]),
            result("l3", #"{"identifier":"SUP-700","title":"New thing"}"#),
            tool("l4", "mcp__claude_ai_Linear__save_issue", ["id": "SUP-191"]),
            result("l4", "not json"),
            tool("l5", "mcp__claude_ai_Linear__save_comment", ["issueId": "SUP-191"]),
            result("l5", #"{"id":"comment-uuid"}"#),
            tool("l6", "mcp__claude_ai_Linear__list_issues", [:]),
            human("look at https://linear.app/supergrow/issue/SUP-9/thing and linear.app/x/issue/SUP-645"),
        ])
        let e = x.events
        expectEqual(e.map(\.kind), [.viewedTicket, .createdTicket, .updatedTicket, .commentedTicket, .mentionedTicket])
        let absorbed = extract([tool("g", "mcp__claude_ai_Linear__get_issue", ["id": "SUP-5"]), result("g"),
                                tool("u", "mcp__claude_ai_Linear__save_issue", ["id": "SUP-5"]), result("u")])
        expectEqual(absorbed.events.map(\.kind), [.updatedTicket])
        expectEqual(e[0].ticket, "SUP-645")
        expectEqual(e[0].title, "Org analytics")
        expectEqual(e[0].url, "https://linear.app/s/issue/SUP-645/org")
        expectEqual(e[1].ticket, "SUP-700")
        expectEqual(e[1].title, "New thing")
        expectEqual(e[3].ticket, "SUP-191")
        expectEqual(e[4].ticket, "SUP-9")
        expectEqual(e[4].url, "https://linear.app/supergrow/issue/SUP-9")
        expect(e.allSatisfy(\.isTicket) && !e[0].isPR)
    }
    test("screenshots: one per turn, page names, files, your images, failures") {
        let tab = "Executed on tabId: 5\n• tabId 5: \"Pricing\" (\"http://localhost:3000/pricing\")"
        let blank = "Executed on tabId: 6\n• tabId 6: \"\" (\"http://localhost:3000/\")"
        let x = extract([
            tool("s1", "mcp__claude-in-chrome__computer", ["action": "screenshot"]),
            result("s1", [["type": "text", "text": tab]]),
            tool("s2", "mcp__computer-use__screenshot", [:]),
            result("s2"),
            say("The pricing page renders the new tier."),
            human("thanks"),
            tool("s3", "Read", ["file_path": "/tmp/shot.PNG"]),
            result("s3"),
            tool("s4", "Read", ["file_path": "/tmp/notes.md"]),                  // not an image
            human("next"),
            tool("s5", "mcp__claude-in-chrome__computer", ["action": "screenshot"]),
            result("s5", "failed", error: true),
            tool("s6", "mcp__x__take_screenshot", [:]),
            result("s6", [["type": "text", "text": blank]]),
            human([["type": "text", "text": "this one"], ["type": "image", "source": [:]], ["type": "image", "source": [:]]]),
            human([["type": "image", "source": [:]]]),
            human("ignored reminder", meta: true),
        ])
        let shots = x.events
        expectEqual(shots.count, 5)
        expectEqual(shots[0].count, 2)
        expectEqual(shots[0].label, "Reviewed 2 screenshots")
        expectEqual(shots[0].detail, "Pricing · http://localhost:3000/pricing")
        expectEqual(shots[0].quote, "The pricing page renders the new tier.")
        expectEqual(shots[1].detail, "shot.PNG")
        expectEqual(shots[1].label, "Reviewed a screenshot")
        // the failed one was dropped, the next starts fresh
        expectEqual(shots[2].detail, "http://localhost:3000/")
        expectEqual(shots[3].detail, "Images you shared")
        expectEqual(shots[3].count, 2)
        expectEqual(shots[4].detail, "An image you shared")
        expect(shots[0].ref == nil)
    }
    test("narration: collected until your next message, capped, and reviews you ask for") {
        let long = String(repeating: "word ", count: 200)
        let x = extract([
            human("<command-name>/review</command-name>\n<command-args>https://github.com/acme/api/pull/77</command-args>"),
            say("Ok."),
            say("   "),
            say(long),
            say(long),
            human("<command-name>/code-review</command-name>\n<command-args>high</command-args>"),   // no PR: nothing
            say("ignored, nobody is listening"),
            human([["type": "text", "text": "hi"]]),
            line(["type": "assistant", "x": "screenshot", "message": ["content": "not blocks"]]),
            line(["type": "assistant", "x": "screenshot", "message": ["content": [["type": "thinking"], ["type": "text"]]]]),
            line(["type": "user", "x": "screenshot", "message": ["content": 5]]),
            line(["type": "user", "x": "screenshot", "message": ["content": [["type": "text"], ["type": "document"]]]]),
            line(["type": "system", "subtype": "x", "content": "screenshot"]),
            line(["type": "ai-title", "aiTitle": "Auto"]),
            Data("{not json screenshot".utf8),
            tool("bad", "Bash", [:]),
            line(["type": "assistant", "x": "screenshot", "message": ["content": [["type": "tool_use", "name": "Bash"]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "noinput", "name": "mcp__x__screenshot"]]]]),
            result("unknown"),
            line(["type": "user", "message": ["content": [["type": "tool_result"]]]]),
        ])
        let r = x.events[0]
        expectEqual(r.kind, .reviewedPR)
        expectEqual(r.number, 77)
        expectEqual(r.repo, "acme/api")
        expectEqual(r.narration?.count, ActivityExtractor.maxNarration)
        expect(r.narration!.hasPrefix("Ok.\nword"))
        expectEqual(r.quote?.count, 180)  // long sentences are cut
        expectEqual(x.title, "Auto")
        expectEqual(x.events.map(\.kind), [.reviewedPR, .screenshot])  // a screenshot tool with no input still counts
    }
    test("code: pushes with their commits, new branches, tags, nothing to push") {
        let x = extract([
            bash("b1", "cd /w/api && git checkout -b deven/sup-610-approvals"),
            result("b1"),
            bash("c1", "git add -A && git commit -q -F - <<'EOF'\nAdd approval step\n\nCo-Authored-By: x\nEOF\ngit push -u origin deven/sup-610-approvals"),
            result("c1", "To github.com:acme/api.git\n * [new branch]      deven/sup-610-approvals -> deven/sup-610-approvals\n"),
            bash("c2", "git commit -m \"Fix typo\""),
            result("c2", "[deven/sup-610-approvals 1a2b3c4] Fix typo\n 1 file changed"),
            bash("c3", "git commit -qm 'Tidy'"),
            result("c3"),
            bash("p2", "git push 2>&1 | tail -2"),
            result("p2", "To https://github.com/acme/api.git\n   1a2b3c4..5d6e7f8  HEAD -> deven/sup-610-approvals\n"),
            bash("p3", "git push"),
            result("p3", "Everything up-to-date"),
            bash("p4", "git push origin v1.2"),
            result("p4", "To github.com:acme/api.git\n * [new tag]         v1.2 -> v1.2\n"),
            bash("p5", "git push --tags"),
            bash("p6", "git push origin --delete old"),
            bash("w1", "git worktree add ../wt -b sup-7-thing origin/main && git switch -c other"),
            result("w1"),
            bash("c4", "git commit -m \"$(cat <<'EOF'\nShip it\nEOF\n)\""),
            result("c4", "boom", error: true),
            bash("p7", "git push"),
            result("p7", "rejected", error: true),
            bash("c5", "git commit -m \"$(git log -1)\""),
            result("c5"),
            bash("p8", "git push 2>&1 | tail -1"),
            result("p8", "done"),
        ])
        let e = x.events
        expectEqual(e.map(\.kind), [.createdBranch, .pushed, .pushed, .createdBranch, .createdBranch, .pushed])
        expectEqual(e[0].refName, "deven/sup-610-approvals")
        expectEqual(e[0].branchTicket, "SUP-610")
        expectEqual(e[0].ref, "deven/sup-610-approvals")
        // The first push and the follow-up push of the same branch are one event.
        expectEqual(e[1].label, "Pushed 3 commits")
        expectEqual(e[1].title, "Tidy")
        expectEqual(e[1].count, 2)
        expectEqual(e[1].repo, "acme/api")
        expectEqual(e[1].detail, "New branch")
        expectEqual(e[1].refName, "deven/sup-610-approvals")
        expectEqual(e[2].label, "Pushed tag")
        expectEqual(e[2].refName, "v1.2")
        expectEqual(e[3].refName, "sup-7-thing")
        expectEqual(e[4].refName, "other")
        expectEqual(e[5].label, "Pushed")  // a commit whose message isn't readable
        expectEqual(e[5].refName, "main")   // output cut, ran in the session's folder
        expect(e.allSatisfy(\.isCode))
        expectEqual(ActivityExtractor.commitSubject(in: "git commit -m ''"), nil)
        expect(ActivityExtractor.commitSubject(in: "git status") == nil)

        // A push from the session's own folder whose output was cut keeps the session's branch.
        let y = extract([bash("p", "git push 2>&1 | tail -1", branch: "feature/x"), result("p", "ok")])
        expectEqual(y.events[0].refName, "feature/x")
        let named = extract([bash("p", "cd /w/other && git push origin HEAD:refs/heads/x"), result("p", "   1..2  HEAD -> feature/y\n"),
                             bash("q", "git commit -m \"One\" && git push"), result("q", "[feature/y 3c4d5e6] One\nTo github.com:a/b\n   2..3  HEAD -> feature/y\n"),
                             line(["type": "user", "message": ["content": [["type": "tool_result", "content": "screenshot"]]]])])
        expectEqual(named.events.map(\.refName), ["x"])
        expectEqual(named.events[0].label, "Pushed a commit")
        let fromOutput = extract([bash("p", "cd /w/o && git push 2>&1"), result("p", " * [new branch]      HEAD -> feat/z\n")])
        expectEqual(fromOutput.events[0].refName, "feat/z")
        let z = extract([bash("p", "git push", branch: "a"), result("p", "ok"), bash("q", "git push", branch: "a"), result("q", "ok"),
                         bash("r", "git push", branch: "a"), result("r", "Everything up-to-date")])
        expectEqual(z.events.map(\.count), [2])
        expectEqual(z.events[0].label, "Pushed 2×")
    }
    test("a look replaced before its result arrives") {
        let x = extract([
            bash("v", "gh pr view 5"),
            bash("m", "gh pr merge 5"),
            result("v"),
            result("m"),
            say("Merged after a look."),
        ])
        expectEqual(x.events.map(\.kind), [.mergedPR])
        expectEqual(x.events[0].narration, "Merged after a look.")
        let y = extract([bash("v", "gh pr view 6"), result("v"), bash("m", "gh pr merge 6"), say("Now merging it all.")])
        expectEqual(y.events.map(\.kind), [.mergedPR])
    }
    test("titles: yours win over Claude's") {
        let x = extract([line(["type": "ai-title", "aiTitle": "Auto"]), line(["type": "custom-title", "customTitle": "Mine"]),
                         line(["type": "ai-title", "aiTitle": "Later"]), line(["type": "custom-title"]), line(["type": "ai-title"])])
        expectEqual(x.title, "Mine")
    }
    test("shell folder resets and the timestamps") {
        let x = extract([
            bash("a", "cd /w/fe"),
            result("a", "Shell cwd was reset to /w/api"),
            bash("b", "gh pr merge 3"),
            result("b"),
            bash("c", "cd \"/w/my app\" && gh pr merge 4 && cd '/w/x' && gh pr merge 5"),
            result("c"),
        ])
        expectEqual(x.events.map(\.dir), ["/w/api", "/w/my app", "/w/x"])
        expectEqual(x.lastAt, Rx.date(t0))
    }
    test("event labels, refs, keys, sentences") {
        var e = ActivityEvent(id: "1", sessionId: "s", kind: .openedPR)
        expect(e.prKey == nil && e.ref == nil && e.isPR && !e.isTicket)
        e.number = 5
        expectEqual(e.prKey, "#5")
        e.repo = "a/b"
        expectEqual(e.prKey, "a/b#5")
        expectEqual(e.ref, "#5")
        let labels = ActivityEvent.Kind.allCases.map { ActivityEvent(id: "", sessionId: "", kind: $0).label }
        expectEqual(Set(labels).count, ActivityEvent.Kind.allCases.count)
        expectEqual(ActivityEvent.trimmed("SUP-1: Fix it", ref: "SUP-1"), "Fix it")
        expectEqual(ActivityEvent.trimmed("sup-1 - Fix", ref: "SUP-1"), "Fix")
        expectEqual(ActivityEvent.trimmed("SUP-1", ref: "SUP-1"), "SUP-1")
        expectEqual(ActivityEvent.trimmed("Other", ref: "SUP-1"), "Other")
        expectEqual(ActivityEvent.trimmed("Plain", ref: nil), "Plain")
        let linked = [ActivityEvent(id: "a", sessionId: "s", kind: .openedPR, url: "https://github.com/x/y/pull/1"),
                      ActivityEvent(id: "b", sessionId: "s", kind: .viewedTicket, url: "https://linear.app/acme/issue/A-1/x")]
        expectEqual(ActivityEvent.linearURL(for: "B-2", in: linked), "https://linear.app/acme/issue/B-2")
        expect(ActivityEvent.linearURL(for: "B-2", in: [linked[0]]) == nil)
        expectEqual(ActivityEvent.sentences("One. Two!\nThree?x. Four"), ["One.", "Two!", "Three?x.", "Four"])
        expect(ActivityEvent(id: "", sessionId: "", kind: .screenshot, narration: "Ok. Fine.").quote == nil)
        expect(ActivityEvent(id: "", sessionId: "", kind: .screenshot).quote == nil)
    }
    test("current work: the branch's ticket and PR, else the latest recent ones") {
        func ev(_ kind: ActivityEvent.Kind, _ n: Int? = nil, ticket: String? = nil, title: String? = nil,
                branch: String? = nil, hoursAgo: Double = 0) -> ActivityEvent {
            ActivityEvent(id: UUID().uuidString, sessionId: "s", kind: kind, at: Date(timeIntervalSince1970: 100_000 - hoursAgo * 3600),
                          branch: branch, number: n, ticket: ticket, title: title)
        }
        let events = [
            ev(.mentionedTicket, ticket: "SUP-1", hoursAgo: 30),
            ev(.linkedPR, 40, branch: "deven/sup-610-x", hoursAgo: 20),
            ev(.openedPR, 41, title: "SUP-610: Approval flow", branch: "other", hoursAgo: 2),
            ev(.updatedTicket, ticket: "SUP-9", title: "Nine", hoursAgo: 1),
            ev(.viewedTicket, ticket: "SUP-10", hoursAgo: 0.5),        // only looked up: not "working on"
            ev(.linkedPR, 99, hoursAgo: 0),
        ]
        let onBranch = CurrentWork.of(events: events, branch: "deven/sup-610-x")!
        expectEqual(onBranch.ticket, "SUP-610")
        // found in a PR title
        expectEqual(onBranch.ticketTitle, "SUP-610: Approval flow")
        expectEqual(onBranch.pr?.number, 40)
        // Work touched before your last few messages is a past task.
        let asks = (0..<4).map { ActivityAsk(id: "m\($0)", at: Date(timeIntervalSince1970: 100_000 - Double(3 - $0) * 1800), text: "t", offset: 0) }
        let moved = CurrentWork.of(events: events, branch: "main", asks: asks)
        expectEqual(moved?.ticket, "SUP-9")    // 1h ago, after the third-to-last message (1h ago)
        expect(moved?.pr == nil)                // #41 was 2h ago: before them
        let viaBranch = CurrentWork.of(events: [ActivityEvent(id: "x", sessionId: "s", kind: .createdBranch, refName: "sup-77-x")], branch: "main")
        expectEqual(viaBranch?.ticket, "SUP-77")
        let recent = CurrentWork.of(events: events, branch: "main")!
        expectEqual(recent.ticket, "SUP-9")
        expectEqual(recent.ticketTitle, "Nine")
        expectEqual(recent.pr?.number, 41)  // a link alone isn't work
        expect(CurrentWork.of(events: [], branch: nil) == nil)
        expect(CurrentWork.of(events: [ev(.screenshot)], branch: "feature/plain") == nil)
        let untitled = CurrentWork.of(events: [ev(.mentionedTicket, ticket: "X-1")], branch: nil)!
        expect(untitled.ticketTitle == nil && untitled.pr == nil)
        expectEqual(CurrentWork.ticketId(fromBranch: "sup-12"), "SUP-12")
        expect(CurrentWork.ticketId(fromBranch: "deven/fix-analytics") == nil)
        expect(CurrentWork.ticketId(fromBranch: "postcast-v2-answer") == nil)
        expect(CurrentWork.ticketId(fromBranch: "") == nil)
        var undated = ev(.openedPR, 5)
        undated.at = nil
        expectEqual(CurrentWork.of(events: [undated], branch: nil)?.pr?.number, 5)
    }
    test("helpers: refs, screenshots, text, bytes, regex") {
        expect(ActivityExtractor.prRef(in: " --json x").number == nil)
        expectEqual(ActivityExtractor.prRef(in: " #12 --web").number, 12)
        expectEqual(ActivityExtractor.text(of: "plain"), "plain")
        expectEqual(ActivityExtractor.text(of: [["type": "text", "text": "a"], ["type": "image"], ["text": "b"]]), "a\nb")
        expectEqual(ActivityExtractor.text(of: 3), "")
        expect(!ActivityExtractor.isScreenshot(name: "Read", input: [:]))
        expect(ActivityExtractor.imageName(name: "X", input: [:]) == nil)
        expectEqual(ActivityExtractor.withoutHeredocs("cat <<EOF > f\nbody\nEOF\necho done"), "cat  > f\necho done")
        expect(Bytes.index(of: Array("a".utf8), in: Data()) == nil)
        expect(!Bytes.contains(Data("abc".utf8), Array("zz".utf8)))
        expect(Bytes.value(after: Array("k\"".utf8), in: Data("k\"unterminated".utf8)) == nil)
        expect(Bytes.value(after: Array("zz".utf8), in: Data("abc".utf8)) == nil)
        expectEqual(Rx.first("(a)(b)?", in: "a")?[2] ?? "none", "none")
        expect(Rx.date("nope") == nil)
    }
    test("state survives saving and loading") {
        var x = extract([bash("p", "gh pr merge 1"), say("Merging.")])
        let data = try JSONEncoder().encode(x)
        var y = try JSONDecoder().decode(ActivityExtractor.self, from: data)
        y.ingest(result("p"))
        y.ingest(say("Merged it."))
        x.ingest(result("p"))
        x.ingest(say("Merged it."))
        expectEqual(y.events, x.events)
        expectEqual(y.events[0].narration, "Merged it.")
    }
}

func activityIndexTests() {
    test("indexes every transcript, then only what's new") {
        let box = Sandbox(); defer { box.cleanup() }
        let a = box.root.appendingPathComponent("claude/projects/-w-api/11111111-1111-4111-8111-111111111111.jsonl")
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (String(decoding: bash("x", "gh pr merge 3"), as: UTF8.self) + "\n").write(to: a, atomically: true, encoding: .utf8)
        box.write("claude/projects/-w-api/notes.txt", "x")
        var index: [String: SessionActivity] = [:]
        let first = ActivityIndex.refresh(&index)
        expectEqual(first, ["11111111-1111-4111-8111-111111111111"])
        let s = index.values.first!
        expectEqual(s.events.map(\.kind), [.mergedPR])
        expectEqual(ActivityIndex.refresh(&index), [])  // nothing new

        // Appended lines (one still being written) are picked up from where it left off.
        let h = try FileHandle(forWritingTo: a)
        try h.seekToEnd()
        try h.write(contentsOf: String(decoding: result("x"), as: UTF8.self).appending("\n").data(using: .utf8)!)
        try h.write(contentsOf: Data(String(decoding: say("Merged PR 3 cleanly now."), as: UTF8.self).utf8))
        try h.close()
        expectEqual(ActivityIndex.refresh(&index).count, 1)
        expect(index.values.first!.events[0].narration == nil, "a partial line waits")
        let h2 = try FileHandle(forWritingTo: a); try h2.seekToEnd(); try h2.write(contentsOf: Data("\n".utf8)); try h2.close()
        _ = ActivityIndex.refresh(&index)
        expectEqual(index.values.first!.events[0].quote, "Merged PR 3 cleanly now.")

        // Saved and loaded back, it carries on without re-reading.
        ActivityIndex.save(Array(index.values) + [SessionActivity(extractor: ActivityExtractor(sessionId: "../evil"), path: "/x")])
        box.write("activity/broken.json", "{")
        var old = index.values.first!
        old.version = 1
        old.extractor = ActivityExtractor(sessionId: "22222222-2222-4222-8222-222222222222")
        ActivityIndex.save([old])                                      // an older index: ignored
        box.write("activity/readme.txt", "x")
        var loaded = ActivityIndex.load()
        expectEqual(loaded.count, 1)
        expectEqual(ActivityIndex.refresh(&loaded), [])

        // A rewritten (shorter) transcript is read again from the start.
        try (String(decoding: bash("y", "gh pr view 8"), as: UTF8.self) + "\n").write(to: a, atomically: true, encoding: .utf8)
        _ = ActivityIndex.refresh(&loaded)
        expectEqual(loaded.values.first!.events.map(\.number), [8])
        var gone = SessionActivity(extractor: ActivityExtractor(sessionId: "g"), path: "/no/such/file")
        expect(!ActivityIndex.update(&gone))
    }
    test("missing folders, stray files, a first line longer than a chunk") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(ActivityIndex.load().isEmpty)
        box.write("claude/projects/not-a-folder", "x")
        var index: [String: SessionActivity] = [:]
        expect(ActivityIndex.refresh(&index).isEmpty)
        ClaudePaths.home = box.root.appendingPathComponent("nowhere")
        expect(ActivityIndex.transcripts().isEmpty)
        let url = box.write("long.jsonl", "{\"pad\":\"" + String(repeating: "z", count: ActivityIndex.chunkSize + 5) + "\"}\n"
                            + String(decoding: bash("x", "gh pr merge 2"), as: UTF8.self) + "\n")
        var s = SessionActivity(extractor: ActivityExtractor(sessionId: "l"), path: url.path)
        expect(ActivityIndex.update(&s))
        expectEqual(s.events.map(\.number), [2])
    }
    test("reads in chunks: lines longer than a chunk, many chunks") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.write("t.jsonl", "")
        var text = String(decoding: bash("x", "gh pr merge 1"), as: UTF8.self) + "\n"
        text += "{\"type\":\"user\",\"pad\":\"" + String(repeating: "z", count: ActivityIndex.chunkSize + 10) + "\"}\n"
        text += String(decoding: result("x"), as: UTF8.self) + "\n" + String(decoding: say("All merged and deployed fine."), as: UTF8.self) + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        var s = SessionActivity(extractor: ActivityExtractor(sessionId: "c"), path: url.path)
        expect(ActivityIndex.update(&s))
        expectEqual(s.offset, UInt64(text.utf8.count))
        expectEqual(s.events.first?.quote, "All merged and deployed fine.")
    }
    test("browse: filter, search, newest first, by day") {
        func ev(_ kind: ActivityEvent.Kind, _ id: String, at: Double?, ticket: String? = nil, title: String? = nil) -> ActivityEvent {
            ActivityEvent(id: id, sessionId: id == "c" ? "other" : "s", kind: kind, at: at.map { Date(timeIntervalSince1970: $0) },
                          number: ticket == nil && kind != .screenshot ? 1 : nil, ticket: ticket, title: title)
        }
        let events = [ev(.mergedPR, "a", at: 100, title: "Fix login"), ev(.viewedTicket, "b", at: 300, ticket: "SUP-1"),
                      ev(.screenshot, "c", at: 200), ev(.openedPR, "d", at: nil)]
        expectEqual(ActivityIndex.browse(events).map(\.id), ["b", "c", "a", "d"])
        expectEqual(ActivityIndex.browse([ev(.openedPR, "e", at: nil), ev(.openedPR, "f", at: 5)]).map(\.id), ["f", "e"])
        expectEqual(ActivityIndex.browse(events, filter: .prs).map(\.id), ["a", "d"])
        expectEqual(ActivityIndex.browse(events, filter: .tickets).map(\.id), ["b"])
        expectEqual(ActivityIndex.browse(events, filter: .screenshots).map(\.id), ["c"])
        let code = [ActivityEvent(id: "p", sessionId: "s", kind: .pushed), ActivityEvent(id: "l", sessionId: "s", kind: .linkedPR),
                    ActivityEvent(id: "b", sessionId: "s", kind: .createdBranch, refName: "sup-3-x")]
        expectEqual(ActivityIndex.browse(code, filter: .code).map(\.id).sorted(), ["b", "p"])
        expectEqual(ActivityIndex.browse(code, filter: .tickets).map(\.id), ["b"])
        expect(ActivityIndex.browse(code).allSatisfy { $0.kind != .linkedPR })
        expectEqual(ActivityIndex.browse(events, query: "  login fix ").map(\.id), ["a"])
        expectEqual(ActivityIndex.browse(events, query: "deck", sessionTitle: { $0 == "other" ? "Claude Deck" : nil }).map(\.id), ["c"])

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = 86_400.0
        let grouped = ActivityIndex.byDay([ev(.mergedPR, "x", at: day * 2 + 5), ev(.mergedPR, "y", at: day * 2 + 1),
                                           ev(.mergedPR, "z", at: day + 1), ev(.mergedPR, "w", at: nil)], calendar: cal)
        expectEqual(grouped.map { $0.events.map(\.id) }, [["x", "y"], ["z"], ["w"]])
        let now = Date(timeIntervalSince1970: day * 400 + 10)
        expectEqual(ActivityIndex.dayLabel(cal.startOfDay(for: now), now: now, calendar: cal), "Today")
        expectEqual(ActivityIndex.dayLabel(now.addingTimeInterval(-day), now: now, calendar: cal), "Yesterday")
        expectEqual(ActivityIndex.dayLabel(.distantPast, now: now, calendar: cal), "Earlier")
        expect(!ActivityIndex.dayLabel(now.addingTimeInterval(-day * 3), now: now, calendar: cal).isEmpty)
        expect(ActivityIndex.dayLabel(now.addingTimeInterval(-day * 300), now: now, calendar: cal).contains(","))
    }
}

func activitySummaryTests() {
    test("PR info from gh, and when it's worth asking again") {
        let now = Date(timeIntervalSince1970: 1000)
        let open = PRInfo.parse(#"{"title":"Fix","state":"OPEN","url":"u","body":"Body text","isDraft":false}"#, at: now)!
        expectEqual(open.state, .open)
        expectEqual(open.body, "Body text")
        expectEqual(PRInfo.parse(#"{"title":"D","state":"OPEN","isDraft":true,"body":""}"#)?.state, .draft)
        expect(PRInfo.parse(#"{"title":"D","state":"OPEN","isDraft":true,"body":""}"#)?.body == nil)
        expect(PRInfo.parse(#"{"title":"x","state":"WEIRD"}"#) == nil)
        expect(PRInfo.parse("nope") == nil)
        expect(open.isStale(now: now.addingTimeInterval(601)))
        expect(!open.isStale(now: now.addingTimeInterval(10)))
        let merged = PRInfo(title: "m", state: .merged, url: nil, body: nil, fetchedAt: now)
        expect(!merged.isStale(now: now.addingTimeInterval(99_999)))
    }
    test("prompts carry the facts; replies are checked") {
        var e = ActivityEvent(id: "s:1", sessionId: "s", kind: .mergedPR, repo: "a/b", number: 4, detail: "squash", narration: "Merged and deployed.")
        let pr = PRInfo(title: "Fix login", state: .merged, url: nil, body: "Long body", fetchedAt: Date())
        let d = ActivitySummarizer.describe(e, pr: pr)
        expectEqual(d["event"], "Merged PR #4 in a/b")
        expectEqual(d["title"], "Fix login")
        expectEqual(d["description"], "Long body")
        expectEqual(d["claude_said"], "Merged and deployed.")
        expectEqual(d["detail"], "squash")
        e.narration = nil
        expectEqual(ActivitySummarizer.describe(e).keys.sorted(), ["detail", "event", "id"])
        let prompt = ActivitySummarizer.eventsPrompt([e], pr: { _ in pr })
        expect(prompt.contains("\"id\":\"s:1\"") && prompt.contains("Fix login"))
        expect(ActivitySummarizer.eventsPrompt([e]).contains("Merged PR #4"))

        let ok = #"{"is_error":false,"structured_output":{"items":[{"id":"s:1","summary":" Merged the login fix. "},{"id":"other","summary":"x"},{"id":"s:1b","summary":""},{"summary":"no id"}]}}"#
        expectEqual(ActivitySummarizer.parseItems(ok, ids: ["s:1", "s:1b"]), ["s:1": "Merged the login fix."])
        let tooLong = #"{"structured_output":{"items":[{"id":"s:1","summary":"\#(String(repeating: "x", count: 300))"}]}}"#
        expect(ActivitySummarizer.parseItems(tooLong, ids: ["s:1"]).isEmpty)
        let viaResult = #"{"result":"{\"items\":[{\"id\":\"s:1\",\"summary\":\"Done.\"}]}"}"#
        expectEqual(ActivitySummarizer.parseItems(viaResult, ids: ["s:1"])["s:1"], "Done.")
        expect(ActivitySummarizer.parseItems(#"{"is_error":true,"result":"x"}"#, ids: ["s:1"]).isEmpty)
        expect(ActivitySummarizer.parseItems(#"{"other":1}"#, ids: ["s:1"]).isEmpty)
        expect(ActivitySummarizer.parseItems("garbage", ids: ["s:1"]).isEmpty)
        expect(ActivitySummarizer.parseItems(#"{"structured_output":{"items":"no"}}"#, ids: ["s:1"]).isEmpty)

        let recap = ActivitySummarizer.recapPrompt(title: "API", events: [e], summaries: ["s:1": "Merged it."])
        expect(recap.contains("Session: API") && recap.contains("- Merged PR #4: Merged it."))
        var shot = ActivityEvent(id: "s:2", sessionId: "t", kind: .screenshot)
        expect(ActivitySummarizer.lines([shot], summaries: [:]).hasSuffix("Reviewed a screenshot"))
        shot.narration = "The page looks right now."
        let digest = ActivitySummarizer.digestPrompt(day: "Today", events: [e, shot], summaries: [:], sessionTitle: { "T-\($0)" })
        expect(digest.contains("Session \"T-s\"") && digest.contains("Session \"T-t\"") && digest.contains("The page looks right now."))
        expectEqual(ActivitySummarizer.parseText(#"{"structured_output":{"text":" Shipped. "}}"#), "Shipped.")
        expect(ActivitySummarizer.parseText(#"{"structured_output":{"text":"  "}}"#) == nil)
        let asks7 = (0..<7).map { ActivityAsk(id: "\($0)", at: nil, text: "message \($0)", offset: 0) }
        let tp = ActivitySummarizer.taskPrompt(asks7, previous: nil)
        expect(tp.contains("- message 6") && !tp.contains("- message 1") && tp.contains("new_task is true."))
        expect(ActivitySummarizer.taskPrompt(asks7, previous: "Old thing").contains("The task before was: Old thing."))
        let parsed = ActivitySummarizer.parseTask(#"{"structured_output":{"task":"“AppSumo integration design.”","new_task":false}}"#)
        expectEqual(parsed?.name, "AppSumo integration design")
        expectEqual(parsed?.isNew, false)
        expectEqual(ActivitySummarizer.parseTask(#"{"structured_output":{"task":"Thing"}}"#)?.isNew, true)
        expect(ActivitySummarizer.parseTask(#"{"structured_output":{"task":"a\nb c"}}"#) == nil)
        expect(ActivitySummarizer.parseTask(#"{"structured_output":{"task":"\"\""}}"#) == nil)
        expect(ActivitySummarizer.parseTask(#"{"structured_output":{"task":"\#(String(repeating: "x", count: 70))"}}"#) == nil)
        expect(ActivitySummarizer.parseTask("nope") == nil)
        let args = ActivitySummarizer.arguments(prompt: "P", schema: "S")
        expect(args.first == "-p" && args.last == "P" && args.contains("haiku") && args.contains("--no-session-persistence"))
        // no tools
        expectEqual(args[args.firstIndex(of: "--tools")! + 1], "")
    }
}
