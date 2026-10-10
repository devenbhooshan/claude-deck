import AppKit
import SwiftUI

/// Sidebar sections listing the skills and MCP servers available in the selected session's project.
struct ToolboxSections: View {
    @Environment(ToolboxStore.self) private var toolbox
    @Environment(SessionStore.self) private var store
    @AppStorage("sidebar.showSkills") private var showSkills = false
    @AppStorage("sidebar.showMCP") private var showMCP = false

    var body: some View {
        Section(isExpanded: $showSkills) {
            if toolbox.skills.isEmpty {
                Text("No skills found").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(toolbox.skills) { skill in
                SkillRow(skill: skill) { use(skill) }
            }
        } header: {
            SectionHeader(title: "Skills", count: toolbox.skills.count, tint: nil)
        }

        Section(isExpanded: $showMCP) {
            if toolbox.cwd == nil {
                Text("Select a session to see its project's MCP servers").font(.callout).foregroundStyle(.tertiary)
            } else if let state = toolbox.mcpState {
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                }
                if state.servers.isEmpty && state.loading {
                    Text("Checking servers…").font(.callout).foregroundStyle(.tertiary)
                } else if state.servers.isEmpty && state.error == nil {
                    Text("No MCP servers").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(state.servers) { MCPRow(server: $0) }
            }
        } header: {
            HStack(spacing: 6) {
                SectionHeader(title: "MCP servers", count: toolbox.mcpState?.servers.count, tint: nil)
                Spacer()
                if toolbox.mcpState?.loading == true {
                    ProgressView().controlSize(.mini)
                } else if toolbox.cwd != nil {
                    Button {
                        toolbox.refreshMCP(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.deckBorderless)
                    .help(toolbox.mcpState?.checkedAt.map { "Checked \(Theme.ago($0)) ago. Check again" } ?? "Check servers")
                }
            }
        }
    }

    /// Puts the skill's command in the message box of the selected running session, or copies it.
    private func use(_ skill: Skill) {
        if let s = store.session(store.selectedId), s.isLive {
            store.composerInsert = skill.command + " "
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(skill.command, forType: .string)
            HUD.show("Copied \(skill.command)", symbol: "doc.on.doc", tint: Theme.accent)
        }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.command)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(skill.scopeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .help(skill.description.isEmpty ? skill.command : skill.description)
        .contextMenu {
            Button("Copy \(skill.command)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.command, forType: .string)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.path]) }
        }
    }
}

private struct MCPRow: View {
    let server: MCPServer

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.callout).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if server.isClaudeAI {
                        Text("claude.ai")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .help(server.target)
    }

    private var color: Color {
        switch server.status {
        case .connected: Theme.success
        case .needsAuth: Theme.waiting
        case .failed: Theme.danger
        case .other: .secondary
        }
    }

    private var statusText: String {
        switch server.status {
        case .connected: server.target
        case .needsAuth: "Needs authentication"
        case .failed: "Failed to connect"
        case .other(let s): s
        }
    }
}
