import SwiftUI

/// The rules checked before every tool call in every session, and what they've caught.
struct PoliciesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Policies.load()
    @State private var installed = PolicyHook.isInstalled
    @State private var events = Policies.recent(limit: 30)
    @State private var confirmInstall = false
    @State private var error: String?

    /// The checker bundled next to Deck's own executable.
    private var checker: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Policies.checkerName)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    rules
                    if !events.isEmpty { recent }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Rules are saved in ~/Library/Application Support/ClaudeDeck/policies.json.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 640, height: 640)
        .background(Theme.surface)
        .task {
            // Pick up new decisions while the sheet is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                events = Policies.recent(limit: 30)
            }
        }
        .confirmationDialog("Check every tool call against these policies?", isPresented: $confirmInstall) {
            Button("Add Hook to ~/.claude/settings.json") { change { try PolicyHook.install(checker: checker) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deck adds a PreToolUse hook that runs its small policy checker before each tool call in every Claude Code session. It blocks or asks only when a rule matches, and works even when Deck isn't open. Your settings are backed up to settings.json.claudedeck-backup first, and running sessions pick it up without a restart.")
        }
        .alert("Couldn't update the policies", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: installed ? "checkmark.shield.fill" : "shield")
                .font(.system(size: 28))
                .foregroundStyle(installed ? Theme.success : Color.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Policies").font(.title3.weight(.semibold))
                Text(installed
                     ? "On. Checked before every tool call in every Claude Code session on this Mac."
                     : "Off. Add the hook to check every tool call in every Claude Code session on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installed {
                Button("Turn Off") { change { try PolicyHook.uninstall() } }
                    .buttonStyle(.deck())
                    .help("Remove the hook from ~/.claude/settings.json. Your rules are kept.")
            } else {
                Button("Turn On…") { confirmInstall = true }
                    .buttonStyle(.deck(.primary))
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules").font(.headline)
            VStack(spacing: 0) {
                PolicyRow(rule: Policies.guardRule, on: .constant(true), locked: true)
                ForEach(Policies.builtins) { rule in
                    Divider().padding(.leading, 12)
                    PolicyRow(rule: rule, on: binding(for: rule), locked: false)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently caught").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        DecisionBadge(decision: e.decision)
                        Text(e.subject)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .help(e.subject)
                        Spacer(minLength: 8)
                        Text(Theme.shortPath(e.cwd)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Text(Theme.ago(e.at)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func binding(for rule: PolicyRule) -> Binding<Bool> {
        Binding(get: { Policies.isOn(rule, in: settings) }, set: { on in
            var next = settings
            next.overrides[rule.id] = on
            change { try Policies.save(next); settings = next }
        })
    }

    private func change(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
        installed = PolicyHook.isInstalled
    }
}

private struct PolicyRow: View {
    let rule: PolicyRule
    @Binding var on: Bool
    let locked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(rule.name).font(.callout.weight(.medium))
                    DecisionBadge(decision: rule.decision)
                }
                Text(rule.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if locked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                    .help("Always on: Claude can't change Deck's policies")
            } else {
                Toggle("", isOn: $on).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .tint(Theme.accent)
                    .pointingHand()
                    .help(on ? "Switch this rule off" : "Switch this rule on")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .opacity(on ? 1 : 0.6)
    }
}

struct DecisionBadge: View {
    let decision: PolicyDecision

    var body: some View {
        let (title, tint): (String, Color) = switch decision {
        case .deny: ("Block", Theme.danger)
        case .ask: ("Ask", Theme.waiting)
        case .allow: ("Allow", Theme.success)
        }
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
