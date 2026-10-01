import Foundation

/// Runs the `claude` command (e.g. `mcp list`, `-p /usage`) and returns what it printed.
enum ClaudeRunner {
    struct RunError: Error { let message: String }

    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 45) -> Result<String, RunError> {
        guard let claude = ClaudeCLI.locate() else { return .failure(RunError(message: "Couldn't find the claude command")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // Apps launched from Finder get a minimal PATH; stdio MCP servers often need npx/uvx etc.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return .failure(RunError(message: error.localizedDescription)) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return .success(String(decoding: data, as: UTF8.self))
    }
}
