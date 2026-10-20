import AppKit
import SwiftUI

/// Writing one of your own rules: what it looks at, what it matches, where, and what happens.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (PolicyRule) -> Void
    let onDelete: () -> Void

    private let id: String
    @State private var name: String
    @State private var scope: PolicyScope
    @State private var kind: PolicyMatch.Kind
    @State private var text: String
    @State private var except: String
    @State private var decision: PolicyDecision
    @State private var message: String
    @State private var folders: [String]
    @State private var trial = ""
    @State private var confirmDelete = false

    init(rule: PolicyRule, isNew: Bool, onSave: @escaping (PolicyRule) -> Void, onDelete: @escaping () -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        id = rule.id
        let m = rule.match ?? PolicyMatch(kind: .regex, text: rule.pattern)
        _name = State(initialValue: rule.name)
        _scope = State(initialValue: PolicyScope(tools: rule.tools))
        _kind = State(initialValue: m.kind)
        _text = State(initialValue: m.text)
        _except = State(initialValue: m.except)
        _decision = State(initialValue: rule.decision)
        _message = State(initialValue: rule.message)
        _folders = State(initialValue: rule.folders ?? [])
    }

    /// The rule as it stands, or nil while the match is empty or invalid.
    private var rule: PolicyRule? {
        Policies.rule(id: id, name: name, scope: scope, match: PolicyMatch(kind: kind, text: text, except: except),
                      decision: decision, message: message, folders: folders)
    }

    /// The kinds that make sense for what the rule looks at.
    private var kinds: [PolicyMatch.Kind] {
        switch scope {
        case .commands: [.contains, .startsWith, .regex]
        case .files: [.path, .contains, .regex]
        case .anyTool: [.contains, .path, .regex]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Rule" : "Edit Rule").font(.title3.weight(.semibold)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        TextField("e.g. No npm publish", text: $name).textFieldStyle(.roundedBorder)
                    }
                    field("When Claude") {
                        Picker("", selection: $scope) {
                            Text("Runs a command").tag(PolicyScope.commands)
                            Text("Reads or edits a file").tag(PolicyScope.files)
                            Text("Uses any tool").tag(PolicyScope.anyTool)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: scope) { if !kinds.contains(kind) { kind = kinds[0] } }
                    }
                    field(scope == .files ? "And the file" : "And it") {
                        HStack(spacing: 8) {
                            Picker("", selection: $kind) {
                                ForEach(kinds, id: \.self) { Text(title(of: $0)).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            TextField(placeholder, text: $text)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty && rule == nil {
                            Label("That pattern isn't a valid regular expression.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.danger)
                        }
                    }
                    field("Unless it also contains (optional)") {
                        TextField(kind == .path ? "e.g. *.example.pem" : "e.g. --dry-run", text: $except)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("Then") {
                        Picker("", selection: $decision) {
                            Text("Block it").tag(PolicyDecision.deny)
                            Text("Ask me first").tag(PolicyDecision.ask)
                            Text("Allow without asking").tag(PolicyDecision.allow)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    field(decision == .deny ? "Tell Claude why" : decision == .ask ? "Show me why" : "Note (optional)") {
                        TextField(decision == .deny ? "e.g. Publishing is done by CI. Ask the user instead." : "e.g. This deploys to production.",
                                  text: $message, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }
                    field("Where") { folderList }
                    field("Try it") { tryIt }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if !isNew {
                    Button("Delete Rule", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.deck())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.deck())
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    if let rule { onSave(rule); dismiss() }
                }
                .buttonStyle(.deck(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(rule == nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 640)
        .background(Theme.surface)
        .confirmationDialog("Delete this rule?", isPresented: $confirmDelete) {
            Button("Delete Rule", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            content()
        }
    }

    private func title(of kind: PolicyMatch.Kind) -> String {
        switch kind {
        case .contains: "contains"
        case .startsWith: "starts with"
        case .path: scope == .files ? "is" : "path is"
        case .regex: "matches regex"
        }
    }

    private var placeholder: String {
        switch kind {
        case .contains: scope == .files ? "e.g. secrets" : "e.g. npm publish"
        case .startsWith: "e.g. git reset --hard"
        case .path: "e.g. *.pem or secrets/**"
        case .regex: #"e.g. \bdocker\s+(rm|rmi)\b"#
        }
    }

    private var hint: String {
        switch kind {
        case .contains: "These words in this order, ignoring case and spacing."
        case .startsWith: "A command that starts with these words, also after ;, && or |."
        case .path: "A file name or path ending. * matches within a folder, ** across folders."
        case .regex: "A regular expression searched in the command or path. (?i) ignores case."
        }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if folders.isEmpty {
                Text("Every folder").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { f in
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(Theme.shortPath(f)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { folders.removeAll { $0 == f } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.deckBorderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this folder")
                }
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.prompt = "Add"
                if panel.runModal() == .OK {
                    for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
                }
            } label: {
                Label(folders.isEmpty ? "Only in certain folders…" : "Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.deck(size: .small))
            .help("Apply this rule only to sessions in these folders and their subfolders")
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(scope == .files ? "A file path, e.g. /Users/me/keys/server.pem" : "A command, e.g. npm publish --tag next",
                      text: $trial)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !trial.isEmpty, let rule {
                let tool = scope == .files ? "Read" : "Bash"
                let hit = Policies.matches(PolicyRule(id: rule.id, name: rule.name, tools: rule.tools, pattern: rule.pattern,
                                                      except: rule.except, decision: rule.decision, message: rule.message),
                                           tool: tool, subject: trial)
                HStack(spacing: 6) {
                    if hit {
                        DecisionBadge(decision: decision)
                        Text("This rule catches it" + (folders.isEmpty ? "." : " in the folders above."))
                    } else {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        Text("This rule doesn't catch it.")
                    }
                }
                .font(.caption)
            }
        }
    }
}
