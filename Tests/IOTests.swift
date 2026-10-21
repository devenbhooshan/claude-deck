import AppKit

private func record(_ pid: Int32, _ id: String, cwd: String = "/p/app", status: String? = "idle",
                    waitingFor: String? = nil, updatedAt: Double = 2_000_000, statusUpdatedAt: Double? = nil,
                    startedAt: Double = 1_000_000) -> String {
    var o: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "startedAt": startedAt, "name": "n-\(id)"]
    if let status { o["status"] = status }
    if let waitingFor { o["waitingFor"] = waitingFor }
    o["updatedAt"] = updatedAt
    if let statusUpdatedAt { o["statusUpdatedAt"] = statusUpdatedAt }
    return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
}

func setMTime(_ url: URL, _ date: Date) {
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

func loaderTests() {
    test("live sessions: status, titles, pending tool, duplicates, dead and bad records") {
        let box = Sandbox(); defer { box.cleanup() }
        let now = Date().timeIntervalSince1970 * 1000
        box.write("claude/sessions/1.json", record(1, "w", status: "waiting", waitingFor: "permission prompt", updatedAt: 3_000_000, statusUpdatedAt: now))
        box.write("claude/sessions/2.json", record(2, "b", status: "busy", startedAt: 500))
        box.write("claude/sessions/3.json", record(3, "i", status: nil))
        box.write("claude/sessions/4.json", record(4, "dead"))
        box.write("claude/sessions/5.json", "{broken")
        box.write("claude/sessions/notes.txt", "ignore")
        box.write("claude/sessions/6.json", record(6, "dup", updatedAt: 5))
        box.write("claude/sessions/7.json", record(7, "dup", updatedAt: 9))
        box.write("claude/sessions/8.json", record(8, "dup", updatedAt: 1))
        box.write("claude/sessions/9.json", record(9, "old", status: "waiting", waitingFor: "permission prompt", statusUpdatedAt: now))
        // A headless run (like Deck's own `claude -p /usage` check) isn't a session you can use.
        box.write("claude/sessions/10.json", #"{"pid":10,"sessionId":"headless","cwd":"/tmp","kind":"interactive","entrypoint":"sdk-cli","status":"busy"}"#)
        box.write("claude/sessions/12.json", record(12, "bg", status: "shell"))
        box.write("claude/sessions/13.json", record(13, "srv", status: "shell"))
        box.write("claude/sessions/11.json", #"{"pid":11,"sessionId":"term","cwd":"/p/app","startedAt":2000000,"entrypoint":"cli"}"#)
        box.jsonl("claude/projects/-p-app/w.jsonl", [["type": "ai-title", "aiTitle": "Waiting one"]])
        box.write("pending/req.a", #"{"session_id":"w","tool_name":"Bash","tool_input":{"command":"rm -rf x"}}"#)
        let old = box.write("pending/req.b", #"{"session_id":"old","tool_name":"Bash","tool_input":{}}"#)
        setMTime(old, Date().addingTimeInterval(-3600))

        let server = BackgroundTask(pid: 50, parent: 13, command: "bin/dev", started: Date(), isServer: true)
        let job = BackgroundTask(pid: 51, parent: 12, command: "make test", started: Date(), isServer: false)
        var reads = 0
        let (live, updates) = SessionLoader.loadLive(cache: [:], alive: { $0 != 4 }, tasks: { reads += 1; return [12: [job], 13: [server]] })
        expectEqual(reads, 1) // the process list is read once
        // Stable order: by start time, then id; status and activity don't move a session.
        expectEqual(live.map(\.id), ["b", "bg", "dup", "i", "old", "srv", "w", "term"])
        let w = live.first { $0.id == "w" }!
        expectEqual(w.title, "Waiting one")
        expectEqual(w.pendingTool?.summary, "rm -rf x")
        expect(live.first { $0.id == "old" }!.pendingTool == nil, "a request from before the prompt opened is ignored")
        expectEqual(live[0].status, .busy)
        expectEqual(live.first { $0.id == "i" }?.status, .idle)
        expectEqual(live.first { $0.id == "bg" }?.status, .background)
        expectEqual(live.first { $0.id == "bg" }?.background, [job])
        // A session running only a server counts as idle, with the server noted.
        let srv = live.first { $0.id == "srv" }!
        expectEqual(srv.status, .idle)
        expect(srv.onlyServers && !live.first { $0.id == "bg" }!.onlyServers && !live.first { $0.id == "i" }!.onlyServers)
        expectEqual(live.first { $0.id == "dup" }?.pid, 7)
        expectEqual(updates.count, 1)
        expect(w.statusSince != nil)
        expectEqual(live[0].startedAt, Date(timeIntervalSince1970: 0.5))
    }
    test("live sessions: a background task the process list doesn't show is still a background task") {
        let box = Sandbox(); defer { box.cleanup() }
        box.write("claude/sessions/\(getpid()).json", #"{"pid":\#(getpid()),"sessionId":"sh","cwd":"/p","status":"shell"}"#)
        let s = SessionLoader.loadLive(cache: [:]).0.first!
        expectEqual(s.status, .background)
        expect(s.background.isEmpty)
    }
    test("live sessions: defaults for missing timestamps; default liveness check") {
        let box = Sandbox(); defer { box.cleanup() }
        let me = getpid()
        box.write("claude/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"a","cwd":"/p","status":"waiting","waitingFor":"permission prompt"}"#)
        box.write("claude/sessions/99999998.json", #"{"pid":99999998,"sessionId":"b","cwd":"/p","startedAt":5000}"#)
        box.write("pending/req.x", #"{"session_id":"a","tool_name":"Edit","tool_input":{"file_path":"/f"}}"#)
        let live = SessionLoader.loadLive(cache: [:]).0
        expectEqual(live.map(\.id), ["a"])
        expectEqual(live[0].updatedAt, Date(timeIntervalSince1970: 0))
        expectEqual(live[0].pendingTool?.summary, "/f") // no status time: any captured request counts
        let started = SessionLoader.loadLive(cache: [:], alive: { _ in true }).0.first { $0.id == "b" }
        expectEqual(started?.updatedAt, Date(timeIntervalSince1970: 5))
        // Sessions without a start time go last, in id order.
        box.write("claude/sessions/99999997.json", #"{"pid":99999997,"sessionId":"c","cwd":"/p"}"#)
        expectEqual(SessionLoader.loadLive(cache: [:], alive: { _ in true }).0.map(\.id), ["b", "a", "c"])
    }
    test("live sessions with no sessions folder") {
        let box = Sandbox(); defer { box.cleanup() }
        try FileManager.default.removeItem(at: ClaudePaths.sessions)
        expect(SessionLoader.loadLive(cache: [:]).0.isEmpty)
    }
    test("recent sessions: last 7 days, excluding live, needing a cwd") {
        let box = Sandbox(); defer { box.cleanup() }
        let now = Date()
        let a = box.jsonl("claude/projects/p1/a.jsonl", [["type": "user", "cwd": "/p/one"], ["type": "ai-title", "aiTitle": "A"]])
        let b = box.jsonl("claude/projects/p1/b.jsonl", [["type": "user", "cwd": "/p/two"]])
        let old = box.jsonl("claude/projects/p1/old.jsonl", [["type": "user", "cwd": "/p/x"]])
        box.jsonl("claude/projects/p2/live.jsonl", [["type": "user", "cwd": "/p/x"]])
        box.jsonl("claude/projects/p2/nocwd.jsonl", [["type": "user"]])
        box.jsonl("claude/projects/p2/script.jsonl", [["type": "queue-operation"], ["type": "user", "cwd": "/p/s", "entrypoint": "sdk-cli"]])
        box.write("claude/projects/p2/readme.md", "x")
        box.write("claude/projects/stray-file", "x")
        setMTime(a, now.addingTimeInterval(-60)); setMTime(b, now.addingTimeInterval(-30))
        setMTime(old, now.addingTimeInterval(-8 * 86400))
        let recent = SessionLoader.loadRecent(excluding: ["live"], cache: [:], now: now)
        expectEqual(recent.map(\.id), ["b", "a"])
        expectEqual(recent[1].title, "A")
        expectEqual(recent[1].status, .ended)
        expect(recent[1].pid == nil)
        expect(!SessionLoader.loadRecent(excluding: [], cache: [:]).isEmpty)
        try FileManager.default.removeItem(at: ClaudePaths.projects)
        expect(SessionLoader.loadRecent(excluding: [], cache: [:]).isEmpty)
    }
    test("titles: cache, custom beats auto, sticky custom, fallbacks") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(SessionLoader.title(for: nil, cache: [:]).0 == nil)
        expect(SessionLoader.title(for: box.root.appendingPathComponent("missing"), cache: [:]).1 == nil)
        let url = box.jsonl("t.jsonl", [["type": "ai-title", "aiTitle": "Auto"], ["type": "custom-title", "customTitle": "Mine"],
                                       ["type": "ai-title", "aiTitle": "Later auto"], ["type": "x-title"]])
        let (t, info) = SessionLoader.title(for: url, cache: [:])
        expectEqual(t, "Mine")
        expect(info?.isCustom == true)
        // Same mtime: served from cache without re-reading.
        let cached = SessionLoader.title(for: url, cache: [url.path: TitleInfo(mtime: info!.mtime, title: "Cached", isCustom: true)])
        expectEqual(cached.0, "Cached")
        expect(cached.1 == nil)
        // Only auto titles in the tail, but we previously saw a custom one: keep it.
        let auto = box.jsonl("u.jsonl", [["type": "ai-title", "aiTitle": "Auto"]])
        let sticky = SessionLoader.title(for: auto, cache: [auto.path: TitleInfo(mtime: .distantPast, title: "Mine", isCustom: true)])
        expectEqual(sticky.0, "Mine")
        expectEqual(SessionLoader.title(for: auto, cache: [:]).0, "Auto")
        // No titles at all: fall back to whatever was cached.
        let none = box.jsonl("n.jsonl", [["type": "user"]])
        expectEqual(SessionLoader.title(for: none, cache: [none.path: TitleInfo(mtime: .distantPast, title: "Prev", isCustom: false)]).0, "Prev")
        expect(SessionLoader.title(for: none, cache: [:]).0 == nil)
    }
    test("non-interactive transcripts") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(SessionLoader.isNonInteractive(box.jsonl("a.jsonl", [["x": 1], ["entrypoint": "sdk-cli"]])))
        expect(!SessionLoader.isNonInteractive(box.jsonl("b.jsonl", [["entrypoint": "cli"]])))
        expect(!SessionLoader.isNonInteractive(box.jsonl("c.jsonl", [["x": 1]])))
    }
    test("cwd and liveness") {
        let box = Sandbox(); defer { box.cleanup() }
        expectEqual(SessionLoader.cwd(of: box.jsonl("c.jsonl", [["cwd": "/a"], ["cwd": "/b"], ["x": 1]])), "/b")
        expect(SessionLoader.cwd(of: box.jsonl("d.jsonl", [["x": 1]])) == nil)
        expect(SessionLoader.isAlive(getpid()))
        expect(SessionLoader.isAlive(1), "launchd exists but isn't ours (EPERM)")
        expect(!SessionLoader.isAlive(99_999_999))
    }
}

func recordTests() {
    test("fresh record read") {
        let box = Sandbox(); defer { box.cleanup() }
        box.write("claude/sessions/42.json", #"{"pid":42,"sessionId":"s","cwd":"/p","status":"waiting","statusUpdatedAt":5}"#)
        expectEqual(SessionLoader.record(pid: 42)?.status, "waiting")
        expect(SessionLoader.record(pid: 43) == nil)
        box.write("claude/sessions/44.json", "{")
        expect(SessionLoader.record(pid: 44) == nil)
    }
}

func pendingTests() {
    test("describe shows the whole request") {
        expectEqual(PendingRequests.describe(name: "Bash", input: ["command": "ls\nrm -rf ~", "description": "list"]), "ls\nrm -rf ~")
        expectEqual(PendingRequests.describe(name: "Read", input: ["file_path": "/f"]), "/f")
        let mcp = PendingRequests.describe(name: "mcp__x__send", input: ["description": "harmless", "to": "everyone"])
        expect(mcp.contains("\"to\" : \"everyone\""), "every parameter is shown")
        expect(PendingRequests.describe(name: "Edit", input: ["file_path": "/f", "new_string": "x"]).contains("new_string"))
        expectEqual(PendingRequests.describe(name: "x", input: nil), "")
    }
    test("prune drops requests whose prompt is gone") {
        let box = Sandbox(); defer { box.cleanup() }
        PendingRequests.prune(keeping: []) // no folder: nothing to do
        let keep = box.write("pending/req.1", #"{"session_id":"a","tool_name":"Bash"}"#)
        let drop = box.write("pending/req.2", #"{"session_id":"b","tool_name":"Bash"}"#)
        let junk = box.write("pending/req.3", "junk")
        PendingRequests.prune(keeping: ["a"])
        let fm = FileManager.default
        expect(fm.fileExists(atPath: keep.path))
        expect(!fm.fileExists(atPath: drop.path) && !fm.fileExists(atPath: junk.path))
    }
    test("install writes through a symlinked settings file") {
        let box = Sandbox(); defer { box.cleanup() }
        let real = box.write("dotfiles/settings.json", #"{"model":"opus"}"#)
        try FileManager.default.createSymbolicLink(at: PendingRequests.settingsURL, withDestinationURL: real)
        try PendingRequests.install()
        let attrs = try FileManager.default.attributesOfItem(atPath: PendingRequests.settingsURL.path)
        expectEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        expect(try String(contentsOf: real, encoding: .utf8).contains("PermissionRequest"))
    }
    test("loads the newest request per session and prunes old files") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(PendingRequests.load().isEmpty, "no folder yet")
        let a = box.write("pending/req.1", #"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"one"}}"#)
        let b = box.write("pending/req.2", #"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"two"}}"#)
        setMTime(a, Date().addingTimeInterval(-60)); setMTime(b, Date().addingTimeInterval(-30))
        let c = box.write("pending/req.3", #"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"older"}}"#)
        setMTime(c, Date().addingTimeInterval(-90))
        box.write("pending/req.4", "not json")
        box.write("pending/req.5", #"{"tool_name":"Bash"}"#)
        let stale = box.write("pending/req.6", #"{"session_id":"t","tool_name":"Bash"}"#)
        setMTime(stale, Date().addingTimeInterval(-2 * 86400))
        let loaded = PendingRequests.load()
        expectEqual(loaded["s"]?.tool.summary, "two")
        expect(loaded["t"] == nil)
        expect(!FileManager.default.fileExists(atPath: stale.path), "day-old requests are deleted")
    }
    test("hook command only observes") {
        expect(PendingRequests.hookCommand.contains("mktemp"))
        expect(!PendingRequests.hookCommand.contains("echo"), "prints nothing, so Claude's dialog still appears")
    }
    test("install: creates, merges, backs up, rejects non-objects") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(!PendingRequests.isInstalled)
        try PendingRequests.install()
        expect(PendingRequests.isInstalled)
        // Existing settings and hooks are kept, and a backup is written (replacing an older one).
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[]}],"PermissionRequest":[{"matcher":"Bash","hooks":[]}]}}"#
            .write(to: PendingRequests.settingsURL, atomically: true, encoding: .utf8)
        box.write("claude/settings.json.claudedeck-backup", "old backup")
        try PendingRequests.install()
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: PendingRequests.settingsURL)) as! [String: Any]
        expectEqual(settings["model"] as? String, "opus")
        let hooks = settings["hooks"] as! [String: Any]
        expect(hooks["Stop"] != nil)
        expectEqual((hooks["PermissionRequest"] as! [Any]).count, 2)
        let backup = try String(contentsOf: PendingRequests.settingsURL.appendingPathExtension("claudedeck-backup"), encoding: .utf8)
        expect(backup.contains("opus"))
        try "[1,2]".write(to: PendingRequests.settingsURL, atomically: true, encoding: .utf8)
        var threw = false
        do { try PendingRequests.install() } catch { threw = true }
        expect(threw, "a settings file that isn't a JSON object is left alone")
    }
}

func purgeTests() {
    test("purges old staged images") {
        let box = Sandbox(); defer { box.cleanup() }
        AttachmentStore.purge() // no folder yet
        let old = box.write("attachments/old.png", "x"), fresh = box.write("attachments/new.png", "x")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: old.path)
        AttachmentStore.purge()
        expect(!FileManager.default.fileExists(atPath: old.path))
        expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}

func attachmentTests() {
    test("files: copied images, converted formats, other files kept by name") {
        let box = Sandbox(); defer { box.cleanup() }
        let png = box.root.appendingPathComponent("shot one.png"); try pngData().write(to: png)
        let a = AttachmentStore.from(fileURL: png)
        expectEqual(a?.url.deletingLastPathComponent().standardizedFileURL.path, AttachmentStore.dir.standardizedFileURL.path)
        expect(!a!.url.path.contains(" "), "saved under a space-free name")
        expect(a!.isImage)
        let tiffURL = box.root.appendingPathComponent("x.tiff"); try image().tiffRepresentation!.write(to: tiffURL)
        expectEqual(AttachmentStore.from(fileURL: tiffURL)?.url.pathExtension, "png")

        let csv = box.write("sales data.csv", "a,b\n1,2")
        let f = AttachmentStore.from(fileURL: csv)!
        expect(!f.isImage)
        expectEqual(f.name, "sales data.csv")
        expectEqual(try String(contentsOf: f.url, encoding: .utf8), "a,b\n1,2")
        expect(f.url.path.hasPrefix(AttachmentStore.dir.path))

        let fakePng = box.write("fake.png", "not an image")
        let fake = AttachmentStore.from(fileURL: fakePng)
        expect(fake?.isImage == false && fake?.name == "fake.png", "a broken image is sent as a file")
        let broken = box.write("broken.tiff", "nope")
        expect(AttachmentStore.from(fileURL: broken)?.isImage == false)

        expect(AttachmentStore.from(fileURL: box.root.appendingPathComponent("missing.png")) == nil)
        expect(AttachmentStore.from(fileURL: box.root) == nil, "folders aren't attached")
        AttachmentStore.dir = box.write("a-file", "x").appendingPathComponent("sub")
        expect(AttachmentStore.from(fileURL: csv) == nil, "unwritable cache")
    }
    test("message: files listed after the text") {
        let a = Attachment(url: URL(fileURLWithPath: "/c/a.csv"), thumbnail: nil)
        let b = Attachment(url: URL(fileURLWithPath: "/c/b.pdf"), thumbnail: nil)
        expectEqual(AttachmentStore.message("hi", files: []), "hi")
        expectEqual(AttachmentStore.message("", files: [a]), "Attached file: /c/a.csv")
        expectEqual(AttachmentStore.message("look", files: [a, b]), "look\n\nAttached file: /c/a.csv\nAttached file: /c/b.pdf")
    }
    test("images: unrenderable or unwritable") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(AttachmentStore.from(image: NSImage(size: NSSize(width: 4, height: 4))) == nil)
        AttachmentStore.dir = box.write("a-file", "x").appendingPathComponent("sub")
        expect(AttachmentStore.from(image: image()) == nil)
    }
    test("pasteboard: files first, then image data, else nothing") {
        let box = Sandbox(); defer { box.cleanup() }
        let png = box.root.appendingPathComponent("p.png"); try pngData().write(to: png)
        let pb = NSPasteboard(name: NSPasteboard.Name("deck-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        pb.clearContents(); pb.writeObjects([png as NSURL])
        expectEqual(AttachmentStore.from(pasteboard: pb).count, 1)
        expect(AttachmentStore.shouldAttach(from: pb))

        pb.clearContents(); pb.writeObjects([image()])
        expectEqual(AttachmentStore.from(pasteboard: pb).count, 1)
        expect(AttachmentStore.shouldAttach(from: pb), "a screenshot attaches")

        pb.clearContents(); pb.writeObjects([image(), "caption" as NSString])
        expect(!AttachmentStore.shouldAttach(from: pb), "rich content with text pastes as text")

        let txt = box.write("t.txt", "x")
        pb.clearContents(); pb.writeObjects([txt as NSURL])
        expectEqual(AttachmentStore.from(pasteboard: pb).first?.isImage, false)
        expect(AttachmentStore.shouldAttach(from: pb), "any copied file attaches")

        expect(AttachmentStore.objects(nil, as: URL.self).isEmpty, "a failed read yields nothing")
        expectEqual(AttachmentStore.objects([1, "a", 2], as: Int.self), [1, 2])

        pb.clearContents(); pb.setString("just text", forType: .string)
        expect(AttachmentStore.from(pasteboard: pb).isEmpty)
        expect(!AttachmentStore.shouldAttach(from: pb))
    }
}
