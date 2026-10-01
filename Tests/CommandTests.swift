import Foundation

func commandTests() {
    test("descriptions from frontmatter or first line") {
        expectEqual(CommandCatalog.describe("---\ndescription: From header\n---\nbody"), "From header")
        expectEqual(CommandCatalog.describe("\n# Error Debugging Protocol\n\nFollow"), "Error Debugging Protocol")
        expectEqual(CommandCatalog.describe("---\nname: x\n---\n\n## Steps"), "Steps")
        expectEqual(CommandCatalog.describe(""), "")
    }
    test("query: only a leading / with no space yet") {
        expectEqual(CommandCatalog.query(in: "/rev"), "rev")
        expectEqual(CommandCatalog.query(in: "/"), "")
        expect(CommandCatalog.query(in: "/review 12") == nil)
        expect(CommandCatalog.query(in: "hi /x") == nil)
    }
    test("matching order: prefix, namespaced prefix, contains, description") {
        let all = [SlashCommand(command: "/review", description: "Review a PR", source: "Built-in"),
                   SlashCommand(command: "/frontend:design", description: "Design help", source: "frontend"),
                   SlashCommand(command: "/pre-review", description: "", source: "Project"),
                   SlashCommand(command: "/clear", description: "Start fresh; review nothing", source: "Built-in")]
        expectEqual(CommandCatalog.matches("rev", in: all).map(\.command), ["/review", "/pre-review", "/clear"])
        expectEqual(CommandCatalog.matches("des", in: all).map(\.command), ["/frontend:design"])
        expectEqual(CommandCatalog.matches("", in: all, limit: 2).count, 2)
        expect(CommandCatalog.matches("zzz", in: all).isEmpty)
        expectEqual(all[0].id, "/review")
    }
    test("collects project, global, plugin commands, skills and built-ins; first name wins") {
        let box = Sandbox(); defer { box.cleanup() }
        let home = box.root.path
        box.write("w/app/.claude/commands/deploy.md", "# Deploy to prod")
        box.write("w/app/.claude/commands/clear.md", "---\ndescription: Project override\n---\n")
        box.write("w/app/.claude/commands/notes.txt", "not a command")
        box.write("w/app/.claude/commands/.hidden.md", "x")
        box.write("claude/commands/team/standup.md", "Write the standup")
        box.write("plugins/p/commands/lint.md", "Lint it")
        box.write("plugins/p/commands/git/pr.md", "Open a PR")
        box.write("claude/plugins/installed_plugins.json", #"{"plugins": {"tools@m": [{"installPath": "\#(home)/plugins/p"}]}}"#)
        // An unreadable .md (a folder named like one) is skipped.
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent("claude/commands/odd.md"), withIntermediateDirectories: true)
        let skill = Skill(name: "pdf", description: "PDFs", scope: .synced, path: box.root)
        let all = CommandCatalog.all(skills: [skill], projectDir: "\(home)/w/app", home: home)
        let commands = all.map(\.command)
        expect(Array(commands.prefix(7)) == ["/clear", "/deploy", "/team:standup", "/tools:git:pr", "/tools:lint", "/pdf", "/usage"],
               "\(commands.prefix(7))")
        expectEqual(all.first { $0.command == "/clear" }?.description, "Project override")
        expectEqual(all.first { $0.command == "/deploy" }?.description, "Deploy to prod")
        expectEqual(all.first { $0.command == "/pdf" }?.source, "claude.ai")
        expectEqual(commands.filter { $0 == "/clear" }.count, 1)
        expect(CommandCatalog.all(skills: [], projectDir: nil, home: home).contains { $0.command == "/help" })
        expect(CommandCatalog.commands(in: box.root, source: "x", depth: 0).isEmpty)
    }
}

func commandKindTests() {
    test("built-ins have the right kind") {
        expectEqual(CommandCatalog.kind(of: "/usage"), .deck)
        expectEqual(CommandCatalog.kind(of: " /model "), .terminal)
        expectEqual(CommandCatalog.kind(of: "/model sonnet"), .send)
        expectEqual(CommandCatalog.kind(of: "/mcp list"), .terminal)
        expectEqual(CommandCatalog.kind(of: "/clear"), .send)
        expectEqual(CommandCatalog.kind(of: "/sg-api-error-debug"), .send)
        expectEqual(CommandCatalog.kind(of: "hello"), .send)
        expect(CommandCatalog.builtIns.contains { $0.kind == .terminal && $0.command == "/config" })
        expectEqual(SlashCommand(command: "/x", description: "", source: "Project").kind, .send)
    }
}

func planUsageTests() {
    test("parses limits, summary and details") {
        let out = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 33% used · resets Oct 1 at 12:49pm (Asia/Calcutta)
        \u{1b}[1mCurrent week (all models)\u{1b}[0m: 18% used · resets Oct 6 at 1:29pm (Asia/Calcutta)
        Current week (Fable): 100% used

        What's contributing to your limits usage?

        Last 24h · 912 requests · 6 sessions
          95% of your usage was at >150k context

        """
        let u = PlanUsage.parse(out)
        expectEqual(u.summary, "You are currently using your subscription to power your Claude Code usage")
        expectEqual(u.limits.map(\.label), ["Current session", "Current week (all models)", "Current week (Fable)"])
        expectEqual(u.limits.map(\.percent), [33, 18, 100])
        expectEqual(u.limits[0].resets, "Oct 1 at 12:49pm (Asia/Calcutta)")
        expectEqual(u.limits[2].resets, "")
        expectEqual(u.limits[0].id, "Current session")
        expectEqual(u.details.first, "What's contributing to your limits usage?")
        expectEqual(u.details.last, "  95% of your usage was at >150k context")
        let empty = PlanUsage.parse("")
        expect(empty.limits.isEmpty && empty.details.isEmpty && empty.summary.isEmpty)
    }
    test("strip ANSI") {
        expectEqual(Safety.stripANSI("\u{1b}[1;32mok\u{1b}[0m \u{1b}[?25l"), "ok ")
    }
}
