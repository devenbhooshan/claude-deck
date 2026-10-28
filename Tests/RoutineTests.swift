import Foundation

func routineTests() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }  // 2026-10-26 is a Monday

    test("schedule: summaries and launchd keys") {
        var s = RoutineSchedule()
        expectEqual(s.summary, "Every day at 9:00")
        s.weekdays = [2, 3, 4, 5, 6]; expectEqual(s.summary, "Weekdays at 9:00")
        s.weekdays = [7, 1]; expectEqual(s.summary, "Weekends at 9:00")
        s.weekdays = Array(1...7); expectEqual(s.summary, "Every day at 9:00")
        s.weekdays = [5, 2]; s.hour = 18; s.minute = 30
        expectEqual(s.summary, "Mon, Thu at 18:30")
        expectEqual(s.launchd["StartCalendarInterval"] as? [[String: Int]],
                    [["Hour": 18, "Minute": 30, "Weekday": 1], ["Hour": 18, "Minute": 30, "Weekday": 4]])
        s.weekdays = []
        expectEqual(s.launchd["StartCalendarInterval"] as? [[String: Int]], [["Hour": 18, "Minute": 30]])
        s.kind = .interval; s.everyHours = 1
        expectEqual(s.summary, "Every hour")
        s.everyHours = 3
        expectEqual(s.summary, "Every 3 hours")
        expectEqual(s.launchd["StartInterval"] as? Int, 10800)
    }
    test("schedule: next and previous runs") {
        var s = RoutineSchedule()
        expectEqual(s.next(after: at("2026-10-26T08:00:00Z"), calendar: cal), at("2026-10-26T09:00:00Z"))
        expectEqual(s.next(after: at("2026-10-26T09:00:00Z"), calendar: cal), at("2026-10-27T09:00:00Z"))
        s.weekdays = [2]  // Mondays
        expectEqual(s.next(after: at("2026-10-26T10:00:00Z"), calendar: cal), at("2026-11-02T09:00:00Z"))
        expectEqual(s.previous(before: at("2026-10-28T10:00:00Z"), calendar: cal), at("2026-10-26T09:00:00Z"))
        s.weekdays = [9]  // not a day
        expectEqual(s.next(after: at("2026-10-26T10:00:00Z"), calendar: cal), at("2026-11-02T10:00:00Z"))
        expect(s.previous(before: at("2026-10-26T10:00:00Z"), calendar: cal) == nil)
        s.kind = .interval; s.everyHours = 2
        expectEqual(s.next(after: at("2026-10-26T10:00:00Z")), at("2026-10-26T12:00:00Z"))
        expectEqual(s.next(after: at("2026-10-26T10:00:00Z"), lastRun: at("2026-10-26T05:30:00Z")), at("2026-10-26T11:30:00Z"))
        expect(s.previous(before: at("2026-10-26T10:00:00Z")) == nil)
    }
    test("missed runs: only daily ones due since the last run, within 12 hours") {
        var r = Routine(name: "x", folder: "/", prompt: "p", created: at("2026-10-01T00:00:00Z"))
        let now = at("2026-10-26T10:00:00Z")
        expect(Routines.missed(r, lastRun: nil, now: now, calendar: cal))
        expect(!Routines.missed(r, lastRun: at("2026-10-26T09:01:00Z"), now: now, calendar: cal), "already ran")
        expect(!Routines.missed(r, lastRun: nil, now: at("2026-10-26T22:00:00Z"), calendar: cal), "too long ago")
        r.created = at("2026-10-26T09:30:00Z")
        expect(!Routines.missed(r, lastRun: nil, now: now, calendar: cal), "made after it was due")
        r.created = at("2026-10-01T00:00:00Z"); r.enabled = false
        expect(!Routines.missed(r, lastRun: nil, now: now, calendar: cal), "paused")
        r.enabled = true; r.schedule.kind = .interval
        expect(!Routines.missed(r, lastRun: nil, now: now, calendar: cal), "intervals catch up by themselves")
    }
    test("arguments: access, model, budget; the prompt is one argument") {
        var r = Routine(name: "Morning", folder: "/w", prompt: "check; rm -rf /")
        let args = Routines.arguments(for: r)
        expectEqual(Array(args.prefix(8)), ["-p", "check; rm -rf /", "--output-format", "json", "--permission-mode", "dontAsk", "--name", "Routine: Morning"])
        expect(!args.contains("--max-budget-usd") && !args.contains("--model") && !args.contains("--session-id"), "no cap, default model")
        expectEqual(args[args.firstIndex(of: "--append-system-prompt")! + 1], Routines.unattended)
        expect(Routines.unattended.contains("unattended") && !Routines.unattended.contains("\\"))
        let withId = Routines.arguments(for: r, sessionId: "abc")
        expectEqual(withId[withId.firstIndex(of: "--session-id")! + 1], "abc")
        expect(args.contains("Bash(git log:*)") && !args.contains("Edit") && !args.contains("Bash"))
        r.access = .canEdit; r.budget = 2.5; r.model = "sonnet"
        let edit = Routines.arguments(for: r)
        expect(edit.contains("Edit") && !edit.contains("Bash"))
        expectEqual(edit[edit.firstIndex(of: "--max-budget-usd")! + 1], "2.50")
        expectEqual(edit[edit.firstIndex(of: "--model")! + 1], "sonnet")
        expect(edit.firstIndex(of: "--allowedTools")! > edit.firstIndex(of: "--model")!, "the tool list comes last")
        r.access = .runCommands
        let all = Routines.allowedTools(.runCommands)
        expect(all.contains("Bash") && all.contains("Write") && !all.contains { $0.hasPrefix("Bash(") })
    }
    test("finishing a run from claude's summary") {
        var run = RoutineRun(id: "1", routine: "r", started: Date())
        let ok = #"{"session_id":"s1","total_cost_usd":0.12,"num_turns":3,"permission_denials":[{},{}],"result":"All green.","is_error":false}"#
        Routines.finish(&run, output: Data(ok.utf8), exitStatus: 0, stderr: "", timedOut: false)
        expectEqual(run.status, .succeeded)
        expectEqual(run.sessionId, "s1"); expectEqual(run.cost, 0.12); expectEqual(run.turns, 3); expectEqual(run.denied, 2)
        expectEqual(run.result, "All green.")
        Routines.finish(&run, output: Data(#"{"is_error":true,"result":"Budget exceeded"}"#.utf8), exitStatus: 1, stderr: "", timedOut: false)
        expectEqual(run.status, .failed); expectEqual(run.result, "Budget exceeded")
        run.sessionId = "chosen"
        Routines.finish(&run, output: Data(), exitStatus: 1, stderr: " boom \n", timedOut: false)
        expectEqual(run.result, "boom")
        expectEqual(run.sessionId, "chosen")  // no summary: the id chosen up front stays
        Routines.finish(&run, output: Data(), exitStatus: 3, stderr: "", timedOut: false)
        expectEqual(run.result, "Claude exited with status 3.")
        Routines.finish(&run, output: Data(#"{"result":""}"#.utf8), exitStatus: 143, stderr: "", timedOut: true)
        expectEqual(run.status, .timedOut); expectEqual(run.result, "Stopped after its time limit.")
        expect(RoutineRun(id: "2", routine: "r", started: Date(), pid: 1).isCutOff { _ in false })
        expect(!RoutineRun(id: "2", routine: "r", started: Date(), pid: 1).isCutOff { _ in true })
        expect(RoutineRun(id: "2", routine: "r", started: Date()).isCutOff { _ in true }, "no helper recorded")
    }
    test("saving, loading, running and history") {
        let box = Sandbox(); defer { box.cleanup() }
        expect(Routines.load().isEmpty && Routines.runs().isEmpty)
        let folder = box.root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r = Routine(name: "Check", folder: folder.path, prompt: "hi")
        try Routines.save(r)
        box.write("routines/broken.json", "{")
        expectEqual(Routines.load(), [r])
        // A stand-in for claude that prints a summary, and records its folder and arguments.
        let fake = box.write("bin/claude", """
            #!/bin/sh
            pwd > "\(box.root.path)/where"
            echo "$@" > "\(box.root.path)/args"
            echo '{"session_id":"abc","total_cost_usd":0.01,"num_turns":1,"result":"Done.","is_error":false}'
            """)
        chmod(fake.path, 0o755)
        let run = Routines.run(r.id, claude: fake.path, now: Date(timeIntervalSince1970: 1_800_000_000))
        expectEqual(run?.status, .succeeded)
        expectEqual(run?.result, "Done.")
        expect(try String(contentsOf: box.root.appendingPathComponent("where"), encoding: .utf8).hasSuffix("/work\n"), "ran in the routine's folder")
        let passed = try String(contentsOf: box.root.appendingPathComponent("args"), encoding: .utf8)
        expect(passed.hasPrefix("-p hi --output-format json") && passed.contains("--session-id "))
        expectEqual(Routines.runs(of: r.id).map(\.status), [.succeeded])
        expectEqual(Routines.runs().count, 1)
        // Already running: skipped.
        let lock = open(Routines.runsDir.appendingPathComponent("\(r.id).lock").path, O_RDWR)
        flock(lock, LOCK_EX)
        expect(Routines.run(r.id, claude: fake.path) == nil)
        close(lock)
        // No claude, no folder, no routine.
        expectEqual(Routines.run(r.id, claude: nil, now: Date(timeIntervalSince1970: 1_800_000_100))?.result, "Couldn't find the claude command.")
        var gone = r; gone.id = "r-gone"; gone.folder = "/nope"
        try Routines.save(gone)
        expect(Routines.run(gone.id, claude: fake.path)?.result?.contains("doesn't exist") == true)
        expect(Routines.run("r-missing", claude: fake.path) == nil)
        // Old runs are pruned; deleting removes the history too.
        Routines.prune(r.id, keep: 1)
        expectEqual(Routines.runs(of: r.id).count, 1)
        Routines.delete(r.id)
        expect(Routines.runs(of: r.id).isEmpty && Routines.routine(r.id) == nil)
        // Unwritable folder.
        Routines.dir = box.write("a-file", "x").appendingPathComponent("sub")
        var threw = false
        do { try Routines.save(r) } catch { threw = true }
        expect(threw)
    }
    test("execute: output, errors, time limit, missing program") {
        let box = Sandbox(); defer { box.cleanup() }
        let ok = Routines.execute("/bin/sh", ["-c", "echo out; echo err >&2; exit 4"], in: "/", timeout: 10)
        expectEqual(String(decoding: ok.output, as: UTF8.self), "out\n"); expectEqual(ok.stderr, "err\n")
        expectEqual(ok.status, 4); expect(!ok.timedOut)
        let slow = Routines.execute("/bin/sh", ["-c", "sleep 5"], in: "/", timeout: 0.3)
        expect(slow.timedOut)
        let missing = Routines.execute(box.root.appendingPathComponent("nope").path, [], in: "/", timeout: 1)
        expectEqual(missing.status, -1)
    }
    test("launchd: the job, installing, pausing, removing") {
        let box = Sandbox(); defer { box.cleanup() }
        let saved = Routines.launchctl; defer { Routines.launchctl = saved }
        let log = box.root.appendingPathComponent("launchctl.log").path
        let fake = box.write("bin/launchctl", "#!/bin/sh\necho \"$@\" >> \"\(log)\"\n")
        chmod(fake.path, 0o755)
        Routines.launchctl = fake.path
        var r = Routine(name: "Check", folder: "/w", prompt: "hi")
        r.schedule.weekdays = [2]
        let job = try PropertyListSerialization.propertyList(from: Routines.plist(for: r, helper: "/A/deck-routine"), format: nil) as! [String: Any]
        expectEqual(job["Label"] as? String, "com.devenbhooshan.claudedeck.routine.\(r.id)")
        expectEqual(job["ProgramArguments"] as? [String], ["/A/deck-routine", "run", r.id])
        expectEqual(job["StartCalendarInterval"] as? [[String: Int]], [["Hour": 9, "Minute": 0, "Weekday": 1]])
        try Routines.install(r, helper: "/A/deck-routine")
        expect(FileManager.default.fileExists(atPath: Routines.plistURL(r.id).path))
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        expect(calls.contains("bootout gui/\(getuid())/\(Routines.label(r.id))") && calls.contains("bootstrap gui/\(getuid()) "))
        r.enabled = false
        try Routines.install(r, helper: "/A/deck-routine")
        expect(!FileManager.default.fileExists(atPath: Routines.plistURL(r.id).path), "paused: unscheduled")
        // launchctl refusing.
        let failing = box.write("bin/launchctl-fail", "#!/bin/sh\necho 'Bootstrap failed: 5' >&2\nexit 5\n")
        chmod(failing.path, 0o755)
        Routines.launchctl = failing.path
        r.enabled = true
        var message = ""
        do { try Routines.install(r, helper: "/A/deck-routine") } catch { message = error.localizedDescription }
        expectEqual(message, "launchctl couldn't schedule it: Bootstrap failed: 5")
        // No LaunchAgents folder possible.
        Routines.agentsDir = box.write("b-file", "x").appendingPathComponent("sub")
        var threw = false
        do { try Routines.install(r, helper: "/A/deck-routine") } catch { threw = true }
        expect(threw)
    }
    test("connectors: names from claude mcp list, as their tools are named") {
        let list = """
            Checking MCP server health…

            claude.ai Slack: https://mcp.slack.com/mcp - ✔ Connected
            claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
            plugin:cloudflare:cloudflare: https://mcp.cloudflare.com/mcp (HTTP) - ! Needs authentication
            nook: /Apps/Nook.app/Contents/MacOS/nook-mcp  - ✔ Connected
            """
        expectEqual(Routines.connectors(fromList: list), ["claude_ai_Slack", "claude_ai_Google_Drive", "plugin_cloudflare_cloudflare", "nook"])
        var r = Routine(name: "x", folder: "/", prompt: "p")
        r.access = .runCommands
        let args = Routines.arguments(for: r, connectors: ["claude_ai_Slack"])
        expectEqual(args.last, "mcp__claude_ai_Slack")
        let reply = Routines.arguments(for: r, prompt: "and now?", resume: "s1")
        expectEqual(Array(reply.prefix(2)), ["-p", "and now?"])
        expectEqual(reply[reply.firstIndex(of: "--resume")! + 1], "s1")
        expect(!reply.contains("--name") && !reply.contains("--session-id"), "a reply continues the run")
    }
    test("replying to a run: continues it, adds up cost and turns") {
        let box = Sandbox(); defer { box.cleanup() }
        let folder = box.root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var r = Routine(name: "Check", folder: folder.path, prompt: "hi")
        r.access = .runCommands
        try Routines.save(r)
        // Answers `mcp list` with one connector, and a run with a summary; records what it was asked.
        let fake = box.write("bin/claude", """
            #!/bin/sh
            echo "$@" >> "\(box.root.path)/calls"
            if [ "$1" = "mcp" ]; then echo 'claude.ai Slack: https://x - ✔ Connected'; exit 0; fi
            echo '{"session_id":"same","total_cost_usd":0.5,"num_turns":2,"result":"Answered.","is_error":false}'
            """)
        chmod(fake.path, 0o755)
        let first = Routines.run(r.id, claude: fake.path)!
        expect(try String(contentsOf: box.root.appendingPathComponent("calls"), encoding: .utf8).contains("mcp__claude_ai_Slack"))
        let replied = Routines.reply(r.id, run: first.id, message: "why?", claude: fake.path)
        expectEqual(replied?.result, "Answered.")
        expectEqual(replied?.cost, 1.0)
        expectEqual(replied?.turns, 4)
        expectEqual(Routines.runs(of: r.id).count, 1)  // the same run, not a new one
        expect(try String(contentsOf: box.root.appendingPathComponent("calls"), encoding: .utf8).contains("-p why? --output-format json --permission-mode dontAsk --resume same"))
        // Can't: unknown run, no claude, or busy.
        expect(Routines.reply(r.id, run: "nope", message: "x", claude: fake.path) == nil)
        expect(Routines.reply(r.id, run: first.id, message: "x", claude: nil) == nil)
        let lock = open(Routines.runsDir.appendingPathComponent("\(r.id).lock").path, O_RDWR)
        flock(lock, LOCK_EX)
        expect(Routines.reply(r.id, run: first.id, message: "x", claude: fake.path) == nil)
        close(lock)
    }
}