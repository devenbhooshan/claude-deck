import Foundation
import Observation

/// Skills and MCP servers for the selected session's project, shown in the sidebar.
@MainActor
@Observable
final class ToolboxStore {
    private(set) var skills: [Skill] = []
    /// Everything you can type after "/" here: custom commands, skills and built-ins.
    private(set) var commands: [SlashCommand] = CommandCatalog.builtIns
    /// The project folder the commands are for (the selected session's cwd).
    private(set) var cwd: String?

    func focus(cwd newCwd: String?) {
        guard newCwd != cwd || skills.isEmpty else { return }
        cwd = newCwd
        loadSkills()
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
}
