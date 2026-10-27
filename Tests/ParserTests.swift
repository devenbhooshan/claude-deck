import AppKit

func pathTests() {
    test("transcript lookup by encoded folder, by scan, or missing") {
        let box = Sandbox(); defer { box.cleanup() }
        box.write("claude/projects/-p-app-x/s1.jsonl", "{}\n")
        box.write("claude/projects/other/s2.jsonl", "{}\n")
        expectEqual(ClaudePaths.transcript(for: "s1", cwd: "/p/app.x")?.lastPathComponent, "s1.jsonl")
        expectEqual(ClaudePaths.transcript(for: "s2", cwd: "/p/app.x")?.deletingLastPathComponent().lastPathComponent, "other")
        expectEqual(ClaudePaths.transcript(for: "s2", cwd: nil)?.lastPathComponent, "s2.jsonl")
        expect(ClaudePaths.transcript(for: "nope", cwd: "/p") == nil)
        try FileManager.default.removeItem(at: ClaudePaths.projects)
        expect(ClaudePaths.transcript(for: "s1", cwd: nil) == nil)
    }
}

func tailTests() {
    test("reads tail, keeps partial lines, resumes, handles truncation") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.write("t.txt", "aaaa\nbbbb\ncc")
        let first = TailReader.read(url, from: nil, maxBytes: 100)
        expectEqual(first.lines.map { String(data: $0, encoding: .utf8)! }, ["aaaa", "bbbb"])
        expectEqual(first.end, 10)
        // From the tail: drops the first (partial) line.
        let tail = TailReader.read(url, from: nil, maxBytes: 7)
        expectEqual(tail.lines.map { String(data: $0, encoding: .utf8)! }, ["bbbb"])
        // Resume after the file grows.
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("c\n".utf8)); try h.close()
        let next = TailReader.read(url, from: first.end, maxBytes: 100)
        expectEqual(next.lines.map { String(data: $0, encoding: .utf8)! }, ["ccc"])
        // Nothing new.
        expect(TailReader.read(url, from: next.end, maxBytes: 100).lines.isEmpty)
        // Truncated below our offset: start over.
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        expectEqual(TailReader.read(url, from: 500, maxBytes: 100).lines.count, 1)
        try "0123456789\nz\n".write(to: url, atomically: true, encoding: .utf8)
        expectEqual(TailReader.read(url, from: 500, maxBytes: 4).lines.map { String(data: $0, encoding: .utf8)! }, ["z"])
        // Missing file.
        let missing = TailReader.read(box.root.appendingPathComponent("nope"), from: 7, maxBytes: 10)
        expect(missing.lines.isEmpty && missing.end == 7)
        expectEqual(TailReader.read(box.root.appendingPathComponent("nope"), from: nil, maxBytes: 10).end, 0)
    }
}

func parserTests() {
    let png = pngData(width: 8, height: 6).base64EncodedString()
    func records() -> [[String: Any]] {
        [
            ["type": "ai-title", "aiTitle": "Auto"],
            ["type": "summary"],
            ["no": "type"],
            ["type": "queue-operation", "operation": "enqueue", "content": "<task-notification>x"],
            ["type": "queue-operation", "operation": "enqueue", "content": "first"],
            ["type": "queue-operation", "operation": "enqueue", "content": "second"],
            ["type": "queue-operation", "operation": "enqueue", "content": "third"],
            ["type": "queue-operation", "operation": "enqueue", "content": "fourth"],
            ["type": "queue-operation", "operation": "enqueue"],
            ["type": "queue-operation", "operation": "dequeue"],   // pops the notification
            ["type": "queue-operation", "operation": "remove", "content": "second"],
            ["type": "queue-operation", "operation": "remove", "content": "never-queued"],
            ["type": "queue-operation", "operation": "remove"],
            ["type": "queue-operation", "operation": "weird"],
            ["type": "user", "uuid": "u1", "timestamp": "2026-10-01T03:13:03.971Z", "message": ["content": "first"]],
            ["type": "user", "isSidechain": true, "message": ["content": "subagent"]],
            ["type": "user", "isMeta": true, "message": ["content": "meta"]],
            ["type": "user", "message": ["content": "<system-reminder>x</system-reminder>"]],
            ["type": "user", "message": ["content": "Caveat: blah"]],
            ["type": "user", "message": ["content": "   "]],
            ["type": "user", "message": ["content": "<command-name>/rename</command-name><command-args>New</command-args>"]],
            ["type": "user", "message": ["content": "<command-message>clear</command-message>"]],
            ["type": "user", "message": ["content": "<local-command-stdout>\u{1b}[1mRenamed\u{1b}[0m</local-command-stdout>"]],
            ["type": "user", "message": ["content": "<local-command-stdout></local-command-stdout>"]],
            ["type": "user", "message": ["content": "<local-command-stdout>unterminated"]],
            ["type": "ai-title"],
            ["type": "user", "message": ["content": "<task-notification><status>failed</status><summary>Build broke</summary></task-notification>"]],
            ["type": "user", "message": ["content": "<task-notification></task-notification>"]],
            ["type": "user", "message": ["content": "[Request interrupted by user]"]],
            ["type": "user", "message": ["content": "<pasted_content id=\"a1\">\nmerge it\n</pasted_content id=\"a1\">"]],
            ["type": "user", "message": ["content": "<pasted_content id=\"a2\">no close"]],
            ["type": "user", "message": ["content": [
                ["type": "text", "text": "[Image #1] look at this"],
                ["type": "image", "source": ["data": png]],
                ["type": "image", "source": ["data": "not-base64!"]],
                ["type": "image"],
                ["type": "other"],
                ["type": "text"],
            ]]],
            ["type": "user", "message": ["content": [["type": "text", "text": "blocks only text"]]]],
            ["type": "user", "message": ["content": [["type": "image", "source": ["data": Data("junk".utf8).base64EncodedString()]]]]],
            ["type": "user", "message": ["content": 5]],
            ["type": "user"],
            ["type": "assistant", "message": ["content": "plain reply"]],
            ["type": "assistant", "message": ["content": [
                ["type": "text", "text": "Let me look."],
                ["type": "text", "text": "   "],
                ["type": "text"],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls -la", "description": "List files"]],
                ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/x"]],
                ["type": "tool_use", "name": "Custom", "input": ["a": 1]],
                ["type": "tool_use", "id": "t4", "name": "NoInput"],
                ["type": "tool_use", "id": "t6"],
                ["type": "thinking"],
                ["type": "thinking", "thinking": "", "signature": "x"],
                ["type": "thinking", "thinking": "Checking the job first."],
            ]]],
            ["type": "assistant", "message": ["content": 5]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "out"],
                ["type": "tool_result", "tool_use_id": "t2", "is_error": true,
                 "content": [["type": "text", "text": "line"], ["type": "image"], ["type": "other"]]],
                ["type": "tool_result", "tool_use_id": "t5", "content": 7],
                ["type": "tool_result"],
            ]]],
            ["type": "attachment", "attachment": ["type": "queued_command", "origin": ["kind": "human"], "prompt": "third"]],
            ["type": "attachment", "attachment": ["type": "queued_command", "origin": ["kind": "system"], "prompt": "ignored"]],
            ["type": "attachment", "attachment": ["type": "other"]],
            ["type": "system", "subtype": "local_command", "content": "<command-name>/cost</command-name><command-args></command-args>"],
            ["type": "system", "subtype": "local_command", "content": "<local-command-stdout>Total cost: $1</local-command-stdout>"],
            ["type": "system", "subtype": "away_summary", "content": "We fixed the bug. (disable recaps in /config)"],
            ["type": "system", "subtype": "away_summary", "content": " (disable recaps in /config)"],
            ["type": "system", "subtype": "informational", "content": "Unknown command: /mco", "timestamp": "2026-10-01T03:13:03.971Z"],
            ["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"],
            ["type": "system", "subtype": "turn_duration"],
            ["type": "system", "subtype": "turn_duration", "content": "12s"],
            ["type": "system", "subtype": "informational", "content": "sub", "isSidechain": true],
            ["type": "custom-title", "customTitle": "Mine"],
            ["type": "ai-title", "aiTitle": "Auto again"],
            ["type": "custom-title", "title": "Legacy"],
            ["type": "custom-title"],
        ]
    }

    test("parses every record type") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.jsonl("t.jsonl", records())
        try FileHandle(forWritingTo: url).write(contentsOf: Data("not json\n".utf8))
        let p = TranscriptParser(url: url)
        expect(p.refresh())
        expect(!p.refresh(), "second refresh with no new data reports no change")
        expectEqual(p.title, "Legacy")
        expectEqual(p.queued, ["fourth"])
        var kinds: [String] = []
        for i in p.items {
            switch i.kind {
            case let .user(t, imgs): kinds.append("user:\(t):\(imgs.count)")
            case .command(let c): kinds.append("cmd:\(c)")
            case .assistant(let t): kinds.append("asst:\(t)")
            case .tool(let c): kinds.append("tool:\(c.name):\(c.summary)" + (c.purpose.map { " (\($0))" } ?? ""))
            case .notice(let t): kinds.append("notice:\(t)")
            case .commandOutput(let t): kinds.append("out:\(t)")
            case .recap(let t): kinds.append("recap:\(t)")
            case let .taskEvent(t, ok): kinds.append("task:\(t):\(ok)")
            }
        }
        expectEqual(kinds, [
            "user:first:0", "cmd:/rename New", "cmd:", "out:Renamed", "task:Build broke:false",
            "task:Background task completed:true", "notice:Interrupted", "user:merge it:0", "user:no close:0",
            "user:look at this:1",
            "user:blocks only text:0", "asst:plain reply", "asst:Let me look.", "tool:Bash:ls -la (List files)", "tool:Read:/x",
            "tool:Custom:{\"a\":1}", "tool:NoInput:", "tool:tool:", "asst:Checking the job first.", "user:third:0",
            "cmd:/cost", "out:Total cost: $1", "recap:We fixed the bug.", "notice:Unknown command: /mco", "notice:Conversation compacted",
        ])
        expect(p.items[0].timestamp != nil)
        expectEqual(p.results["t1"]?.text, "out")
        expectEqual(p.results["t2"]?.text, "line\n[image]")
        expect(p.results["t2"]?.isError == true)
        expectEqual(p.results["t5"]?.text, "")
        // NoInput (t4) is the latest call without a result.
        expectEqual(p.pendingTool?.name, "tool")
    }

    test("pending tool is nil once the last call has a result, or with no calls") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.jsonl("t.jsonl", [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "a", "name": "Bash", "input": ["command": "x"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "a", "content": "ok"]]]],
            ["type": "assistant", "message": ["content": "done"]],
        ])
        let p = TranscriptParser(url: url); p.refresh()
        expect(p.pendingTool == nil)
        let empty = TranscriptParser(url: box.jsonl("e.jsonl", [["type": "assistant", "message": ["content": "hi"]]]))
        empty.refresh()
        expect(empty.pendingTool == nil)
    }

    test("popAll clears the queue; custom title beats later ai-title") {
        let box = Sandbox(); defer { box.cleanup() }
        let p = TranscriptParser(url: box.jsonl("q.jsonl", [
            ["type": "queue-operation", "operation": "enqueue", "content": "a"],
            ["type": "queue-operation", "operation": "popAll"],
            ["type": "queue-operation", "operation": "dequeue"],
            ["type": "custom-title", "customTitle": "Mine"],
            ["type": "ai-title", "aiTitle": "Auto"],
        ]))
        p.refresh()
        expect(p.queued.isEmpty)
        expectEqual(p.title, "Mine")
    }

    test("keeps at most maxItems") {
        let box = Sandbox(); defer { box.cleanup() }
        let recs = (0..<(TranscriptParser.maxItems + 5)).map { ["type": "assistant", "message": ["content": "m\($0)"]] as [String: Any] }
        let p = TranscriptParser(url: box.jsonl("m.jsonl", recs)); p.refresh()
        expectEqual(p.items.count, TranscriptParser.maxItems)
    }

    test("summaries and truncation") {
        expectEqual(TranscriptParser.summarize(name: "x", input: nil), "")
        expectEqual(TranscriptParser.summarize(name: "x", input: ["command": ""]), "{\"command\":\"\"}")
        expectEqual(TranscriptParser.summarize(name: "x", input: ["skill": "pdf"]), "pdf")
        let long = String(repeating: "a", count: 400)
        expectEqual(TranscriptParser.summarize(name: "x", input: ["command": long]).count, 301)
        expect(TranscriptParser.thumbnail(Data("junk".utf8)) == nil)
        let thumb = TranscriptParser.thumbnail(pngData(width: 2000, height: 1000))!
        expectEqual(thumb.size, NSSize(width: 320, height: 160))
        let box = Sandbox(); defer { box.cleanup() }
        let big = String(repeating: "b", count: 9000)
        let p = TranscriptParser(url: box.jsonl("r.jsonl", [
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "r", "content": big]]]],
        ]))
        p.refresh()
        expectEqual(p.results["r"]?.text.count, 8001)
    }
}
