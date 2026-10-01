import Foundation

func skillTests() {
    test("frontmatter: plain, quoted, folded, missing") {
        let fm = SkillCatalog.frontmatter("---\nname: a\ndescription: \"quoted: yes\"\nother: 'single'\nfolded: >\n  line one\n  line two\nbare\nempty: |\n---\nbody: no\n")
        expectEqual(fm["name"], "a")
        expectEqual(fm["description"], "quoted: yes")
        expectEqual(fm["other"], "single")
        expectEqual(fm["folded"], "line one line two")
        expectEqual(fm["empty"], "")
        expect(fm["body"] == nil)
        expect(SkillCatalog.frontmatter("no header").isEmpty)
        expect(SkillCatalog.frontmatter("").isEmpty)
        expectEqual(SkillCatalog.frontmatter("---\nx: \"\n---")["x"], "\"")
    }
    test("project folders walk up to home") {
        expectEqual(SkillCatalog.projectDirs(from: "/Users/me/w/app/sub", home: "/Users/me").map(\.path),
                    ["/Users/me/w/app/sub", "/Users/me/w/app", "/Users/me/w"])
        expect(SkillCatalog.projectDirs(from: "/tmp/x", home: "/Users/me").isEmpty)
    }
    test("loads project, global, synced and enabled plugin skills") {
        let box = Sandbox(); defer { box.cleanup() }
        let home = box.root.path
        box.write("w/app/.claude/skills/blog/SKILL.md", "---\nname: blog\ndescription: Write posts\n---\n")
        box.write("w/.claude/skills/shared/SKILL.md", "---\nname: shared\n---\n")
        box.write("claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: PDFs\n---\n")
        box.write("claude/skills/nameless/SKILL.md", "no frontmatter")
        box.write("claude/skills/group/inner/SKILL.md", "---\nname: inner\n---\n")
        box.write("claude/skills/.hidden/SKILL.md", "---\nname: hidden\n---\n")
        box.write("claude/skills/synced/acct/morning/SKILL.md", "---\nname: morning\n---\n")
        box.write("claude/skills/notes.txt", "x")
        // Symlinked skill folder.
        box.write("elsewhere/linked/SKILL.md", "---\nname: linked\n---\n")
        try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("claude/skills/linked"),
                                                   withDestinationURL: box.root.appendingPathComponent("elsewhere/linked"))
        box.write("plugins/on/skills/design/SKILL.md", "---\nname: design\n---\n")
        box.write("plugins/off/skills/nope/SKILL.md", "---\nname: nope\n---\n")
        box.write("plugins/unlisted/skills/extra/SKILL.md", "---\nname: extra\n---\n")
        box.write("claude/plugins/installed_plugins.json", """
        {"plugins": {
          "frontend@market": [{"installPath": "\(home)/plugins/on"}],
          "off@market": [{"installPath": "\(home)/plugins/off"}],
          "unlisted@x": [{"installPath": "\(home)/plugins/unlisted"}],
          "broken@x": [{}]
        }}
        """)
        box.write("claude/settings.json", #"{"enabledPlugins": {"frontend@market": true, "off@market": false}}"#)

        let skills = SkillCatalog.load(projectDir: "\(home)/w/app", home: home)
        expectEqual(skills.map(\.command), ["/blog", "/shared", "/group", "/inner", "/linked", "/nameless", "/pdf", "/morning",
                                            "/frontend:design", "/unlisted:extra"].filter { $0 != "/group" })
        expectEqual(skills.first?.description, "Write posts")
        expectEqual(skills.first { $0.name == "morning" }?.scopeLabel, "claude.ai")
        expectEqual(skills.first { $0.name == "pdf" }?.scopeLabel, "Global")
        expectEqual(skills.first { $0.name == "blog" }?.scopeLabel, "Project")
        expectEqual(skills.first { $0.name == "design" }?.scopeLabel, "frontend")
        expectEqual(skills.first?.id, "Project/blog")
        // Without a project: no project skills; duplicates collapse.
        expect(!SkillCatalog.load(projectDir: nil, home: home).contains { $0.scope == .project })
        box.write("claude/skills/blog2/SKILL.md", "---\nname: pdf\n---\n")
        expectEqual(SkillCatalog.load(projectDir: nil, home: home).filter { $0.name == "pdf" }.count, 1)
        // No registry / malformed registry: no plugin skills.
        try "nope".write(to: ClaudePaths.home.appendingPathComponent("plugins/installed_plugins.json"), atomically: true, encoding: .utf8)
        expect(SkillCatalog.enabledPlugins().isEmpty)
        try FileManager.default.removeItem(at: ClaudePaths.home.appendingPathComponent("settings.json"))
        try #"{"plugins": {"p@m": [{"installPath": "/x"}]}}"#.write(to: ClaudePaths.home.appendingPathComponent("plugins/installed_plugins.json"),
                                                                   atomically: true, encoding: .utf8)
        expectEqual(SkillCatalog.enabledPlugins().map(\.name), ["p"])
    }
}

func mcpTests() {
    test("parses claude mcp list output") {
        let out = """
        Checking MCP server health…

        claude.ai Slack: https://mcp.slack.com/mcp - ✔ Connected
        newrelic: npx -y newrelic-mcp - ✗ Failed to connect
        linear: https://mcp.linear.app/mcp - ! Needs authentication
        odd: thing - ? Pending
        broken line without separator
        weird - x: y
        """
        let servers = MCPCatalog.parse(out)
        expectEqual(servers.map(\.name), ["claude.ai Slack", "newrelic", "linear", "odd"])
        expectEqual(servers.map(\.status), [.connected, .failed, .needsAuth, .other("? Pending")])
        expectEqual(servers[0].target, "https://mcp.slack.com/mcp")
        expectEqual(servers[0].id, "claude.ai Slack")
        expect(servers[0].isClaudeAI && servers[0].displayName == "Slack")
        expect(!servers[1].isClaudeAI && servers[1].displayName == "newrelic")
        expectEqual(MCPCatalog.status("✗ Not connected"), .failed)
    }
    test("finds the claude command") {
        expectEqual(ClaudeCLI.locate(candidates: ["/a", "/b"], isExecutable: { $0 == "/b" }), "/b")
        expect(ClaudeCLI.locate(candidates: ["/a"], isExecutable: { _ in false }) == nil)
        expect(ClaudeCLI.defaultCandidates.contains { $0.hasSuffix("/.local/bin/claude") })
        _ = ClaudeCLI.locate()
    }
}
