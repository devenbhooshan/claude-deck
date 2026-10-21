import SwiftUI

/// The rules checked before every tool call in every session, and what they've caught.
struct PoliciesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Policies.load()
    @State private var installed = PolicyHook.isInstalled
    @State private var events = Policies.recent(limit: 30)
    @State private var confirmInstall = false
    @State private var error: String?
    /// The rule open in the editor (a new one has an id not in your rules yet).
    @State private var editing: EditingRule?
    @State private var trial = ""
    @State private var suggesting: SuggestState = .idle
    /// A suggestion opened in the editor, removed from the list once added.
    @State private var editingSuggestion: String?

    /// The checker bundled next to Deck's own executable.
    private var checker: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Policies.checkerName)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tester
                    yourRules
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
        .sheet(item: $editing) { e in
            RuleEditor(rule: e.rule, isNew: e.isNew,
                       onSave: { rule in
                           save(rule)
                           if editingSuggestion == rule.id { dropSuggestion(rule.id) }
                       },
                       onDelete: { delete(e.rule.id) })
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

    /// Type a command or path to see which rule would catch it.
    private var tester: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Try a command or file path, e.g. git push --force", text: $trial)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !trial.isEmpty {
                let caught = Policies.evaluate(tool: trial.hasPrefix("/") || trial.hasPrefix("~") ? "Read" : "Bash",
                                               input: [trial.hasPrefix("/") || trial.hasPrefix("~") ? "file_path" : "command": trial],
                                               settings: settings)
                HStack(spacing: 6) {
                    if let caught {
                        DecisionBadge(decision: caught.decision)
                        Text(caught.name).font(.caption.weight(.medium))
                        Text("· \(caught.message)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
                        Text("No rule catches this; Claude goes ahead as usual.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var yourRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your rules").font(.headline)
                Spacer()
                Button { suggest() } label: {
                    Label("Suggest from History", systemImage: "sparkles")
                }
                .buttonStyle(.deck(size: .small))
                .disabled(suggesting.isBusy)
                .help("Claude reads what your sessions ran in the last 30 days and suggests rules for the risky parts")
                Button {
                    editing = EditingRule(rule: PolicyRule(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "",
                                                           tools: ["Bash"], pattern: "", except: nil, decision: .deny, message: "",
                                                           match: PolicyMatch(kind: .contains, text: "")), isNew: true)
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .buttonStyle(.deck(size: .small))
            }
            suggestions
            if settings.rules.isEmpty {
                Text("Add rules for your own risky commands, files or folders. Each one blocks, asks or allows.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                card {
                    ForEach(Array(settings.rules.enumerated()), id: \.element.id) { i, rule in
                        if i > 0 { Divider().padding(.leading, 12) }
                        PolicyRow(rule: rule, on: binding(for: rule), locked: false,
                                  onEdit: { editing = EditingRule(rule: rule, isNew: false) })
                            .contextMenu {
                                Button("Edit…") { editing = EditingRule(rule: rule, isNew: false) }
                                Button("Delete", role: .destructive) { delete(rule.id) }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        switch suggesting {
        case .idle:
            EmptyView()
        case .reading, .asking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(suggesting == .reading ? "Reading the last 30 days of sessions…" : "Claude is looking for risky commands…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { suggesting = .idle }.buttonStyle(.deckBorderless)
            }
        case .done(let found, let calls):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(found.isEmpty ? "No new rules to suggest from \(calls) tool calls: your rules already cover the risky ones."
                                       : "Suggested from \(calls) tool calls in the last 30 days")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss All") { suggesting = .idle }.buttonStyle(.deckBorderless).font(.callout)
                }
                ForEach(found) { s in
                    SuggestionCard(suggestion: s,
                                   onAdd: { save(s.rule); dropSuggestion(s.id) },
                                   onEdit: { editingSuggestion = s.id; editing = EditingRule(rule: s.rule, isNew: true) },
                                   onDismiss: { dropSuggestion(s.id) })
                }
            }
        }
    }

    /// Reads your history, asks Claude for rules, and checks each against what your sessions ran.
    private func suggest() {
        suggesting = .reading
        let existing = Policies.active(settings)
        Task.detached(priority: .userInitiated) {
            let calls = PolicyHistory.calls(days: 30)
            let families = PolicyHistory.families(calls)
            guard !families.isEmpty else {
                await MainActor.run { suggesting = .failed("No commands in your sessions from the last 30 days.") }
                return
            }
            await MainActor.run { suggesting = .asking }
            let prompt = PolicySuggestions.prompt(families: families, days: 30, existing: existing)
            let run = ClaudeRunner.run(ActivitySummarizer.arguments(prompt: prompt, schema: PolicySuggestions.schema, model: "sonnet"),
                                       in: NSHomeDirectory(), timeout: 180)
            let found = (try? run.get()).map { PolicySuggestions.parse($0, calls: calls) }
            await MainActor.run {
                if let found { suggesting = .done(found, calls: calls.count) } else { suggesting = .failed("Couldn't reach Claude. Try again.") }
            }
        }
    }

    private func dropSuggestion(_ id: String) {
        if case .done(var found, let calls) = suggesting {
            found.removeAll { $0.id == id }
            suggesting = .done(found, calls: calls)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func save(_ rule: PolicyRule) {
        var next = settings
        if let i = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[i] = rule } else { next.rules.append(rule) }
        change { try Policies.save(next); settings = next }
    }

    private func delete(_ id: String) {
        var next = settings
        next.rules.removeAll { $0.id == id }
        next.overrides[id] = nil
        change { try Policies.save(next); settings = next }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in rules").font(.headline)
            ForEach(Policies.groups, id: \.title) { group in
                Text(group.title.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                card {
                    ForEach(Array(group.ids.compactMap { id in Policies.builtins.first { $0.id == id } }.enumerated()), id: \.element.id) { i, rule in
                        if i > 0 { Divider().padding(.leading, 12) }
                        PolicyRow(rule: rule, on: binding(for: rule), locked: false)
                    }
                }
            }
            Text("ALWAYS ON").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            card { PolicyRow(rule: Policies.guardRule, on: .constant(true), locked: true) }
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

private enum SuggestState: Equatable {
    case idle, reading, asking
    case done([PolicySuggestions.Suggestion], calls: Int)
    case failed(String)

    var isBusy: Bool { self == .reading || self == .asking }
}

/// One suggested rule: what it catches, why, and what it would have caught in your history.
struct SuggestionCard: View {
    let suggestion: PolicySuggestions.Suggestion
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let s = suggestion
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(Theme.accent)
                Text(s.rule.name).font(.callout.weight(.medium))
                DecisionBadge(decision: s.rule.decision)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.deckBorderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss this suggestion")
            }
            Text(PolicyRow.summary(of: s.rule)).font(.caption).foregroundStyle(.secondary)
            if !s.why.isEmpty { Text(s.why).font(.caption) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Would have \(s.rule.decision == .deny ? "blocked" : "asked") \(s.hits.count)× in \(s.hits.sessions.count) session\(s.hits.sessions.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let e = s.hits.example {
                    Text(e).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(e)
                }
            }
            HStack(spacing: 8) {
                Button("Add Rule", action: onAdd).buttonStyle(.deck(.primary, size: .small))
                Button("Edit First…", action: onEdit).buttonStyle(.deck(size: .small))
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.accent.opacity(0.2)))
    }
}

private struct EditingRule: Identifiable {
    var rule: PolicyRule
    var isNew: Bool
    var id: String { rule.id }
}

private struct PolicyRow: View {
    let rule: PolicyRule
    @Binding var on: Bool
    let locked: Bool
    var onEdit: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(rule.name).font(.callout.weight(.medium))
                    DecisionBadge(decision: rule.decision)
                    if let folders = rule.folders, !folders.isEmpty {
                        Label(folders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), systemImage: "folder")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(onEdit != nil ? summary : rule.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.deckBorderless)
                    .opacity(hovering ? 1 : 0)
                    .help("Edit this rule")
            }
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit?() }
    }

    private var summary: String { Self.summary(of: rule) }

    /// Your rule in words: "Commands containing npm publish".
    static func summary(of rule: PolicyRule) -> String {
        guard let m = rule.match else { return rule.message }
        let what = switch PolicyScope(tools: rule.tools) {
        case .commands: "Commands"
        case .files: "Files"
        case .anyTool: "Any tool call"
        }
        let how = switch m.kind {
        case .contains: "containing"
        case .startsWith: "starting with"
        case .path: "matching"
        case .regex: "matching the pattern"
        }
        return "\(what) \(how) \(m.text)" + (m.except.isEmpty ? "" : ", unless \(m.except)")
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
