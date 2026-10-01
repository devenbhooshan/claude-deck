import Foundation
import Observation

/// Skills and MCP servers for the selected session's project, shown in the sidebar.
@MainActor
@Observable
final class ToolboxStore {
    struct MCPState {
        var servers: [MCPServer] = []
        var checkedAt: Date?
        var loading = false
        var error: String?
    }

    private(set) var skills: [Skill] = []
    /// Everything you can type after "/" here: custom commands, skills and built-ins.
    private(set) var commands: [SlashCommand] = CommandCatalog.builtIns
    private(set) var mcp: [String: MCPState] = [:]
    /// The project folder the toolbox is showing (the selected session's cwd).
    private(set) var cwd: String?

    var mcpState: MCPState? { cwd.flatMap { mcp[$0] } }

    func focus(cwd newCwd: String?) {
        if newCwd != cwd || skills.isEmpty {
            cwd = newCwd
            loadSkills()
        }
        refreshMCP(force: false)
    }

    func loadSkills() {
        let dir = cwd
        Task.detached(priority: .utility) {
            let found = SkillCatalog.load(projectDir: dir)
            let commands = CommandCatalog.all(skills: found, projectDir: dir)
            await MainActor.run {
                guard self.cwd == dir else { return }
                self.skills = found
                self.commands = commands
            }
        }
    }

    /// Runs `claude mcp list` in the project folder. It connects to each server, so it takes a few
    /// seconds; results are cached for 10 minutes. Only ever run for folders you've used Claude Code in.
    func refreshMCP(force: Bool) {
        guard let dir = cwd else { return }
        if !force, let state = mcp[dir],
           state.loading || (state.checkedAt.map { Date().timeIntervalSince($0) < 600 } ?? false) { return }
        mcp[dir, default: MCPState()].loading = true
        Task.detached(priority: .utility) {
            let result = Self.runMCPList(in: dir)
            await MainActor.run {
                var state = self.mcp[dir] ?? MCPState()
                state.loading = false
                state.checkedAt = Date()
                switch result {
                case .success(let servers): state.servers = servers; state.error = nil
                case .failure(let error): state.error = error.message
                }
                self.mcp[dir] = state
            }
        }
    }

    struct RunError: Error { let message: String }

    nonisolated private static func runMCPList(in dir: String) -> Result<[MCPServer], RunError> {
        guard let claude = ClaudeCLI.locate() else { return .failure(RunError(message: "Couldn't find the claude command")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["mcp", "list"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // Apps launched from Finder get a minimal PATH; stdio servers often need npx/uvx etc.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return .failure(RunError(message: error.localizedDescription)) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return .success(MCPCatalog.parse(String(decoding: data, as: UTF8.self)))
    }
}
