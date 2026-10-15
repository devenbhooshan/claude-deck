import Foundation

/// Runs the `claude` command (e.g. `mcp list`, `-p /usage`) and returns what it printed.
enum ClaudeRunner {
    struct RunError: Error { let message: String }

    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 45) -> Result<String, RunError> {
        guard let claude = ClaudeCLI.locate() else { return .failure(RunError(message: "Couldn't find the claude command")) }
        return execute(claude, args, in: dir, timeout: timeout)
    }

    /// Runs GitHub's `gh` (for PR titles and status). Fails when it isn't installed.
    static func gh(_ args: [String], in dir: String, timeout: TimeInterval = 20) -> Result<String, RunError> {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(RunError(message: "Couldn't find the gh command"))
        }
        return execute(gh, args, in: dir, timeout: timeout)
    }

    /// Runs a command (in `dir`, or home if that folder is gone) and returns what it printed.
    private static func execute(_ path: String, _ args: [String], in dir: String, timeout: TimeInterval) -> Result<String, RunError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var isDir: ObjCBool = false
        let usable = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
        p.currentDirectoryURL = URL(fileURLWithPath: usable ? dir : NSHomeDirectory())
        // Apps launched from Finder get a minimal PATH; stdio MCP servers often need npx/uvx etc.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        // No input: otherwise `claude -p` waits a few seconds for stdin first.
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(RunError(message: error.localizedDescription)) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return .success(String(decoding: data, as: UTF8.self))
    }
}
