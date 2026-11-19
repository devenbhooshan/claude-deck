import SwiftUI

/// Your snippets, kept in sync with snippets.json, and the open Snippets sheet.
@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var library = Snippets.load()
    /// Drives the Snippets sheet: which session it was opened for (nil: none selected).
    var sheet: SnippetsTarget?

    func change(_ edit: (inout SnippetLibrary) -> Void) {
        edit(&library)
        Snippets.save(library)
    }

    func open(for session: Session?) {
        sheet = SnippetsTarget(sessionId: session?.sessionId, title: session?.displayTitle)
    }
}

struct SnippetsTarget: Identifiable {
    let sessionId: String?
    let title: String?
    var id: String { sessionId ?? "" }
}

/// Add, edit and delete snippets, and pick the ones added to every message in a session.
struct SnippetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: SnippetsTarget
    @State private var editing: Snippet?
    @State private var isNew = false
    @State private var suggesting: SnippetSuggestState = .idle

    private var store: SnippetStore { .shared }
    private var session: String? { target.sessionId }

    private var everywhere: [Snippet] { store.library.snippets.filter { $0.scope == .global } }
    private var here: [Snippet] { store.library.snippets.filter { session != nil && $0.scope == .session(session!) } }
    private var elsewhere: [Snippet] { store.library.snippets.filter { $0.scope != .global && !$0.applies(to: session) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.library.snippets.isEmpty && editing == nil {
                        Text("No snippets yet. Add the instructions you keep retyping, like “Keep replies short and crisp.”")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let editing { editor(editing) }
                    suggestions
                    group("Everywhere", everywhere)
                    if let title = target.title { group("Only in \(title)", here) }
                    group("Other sessions", elsewhere, everyMessage: false)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Saved in ~/Library/Application Support/ClaudeDeck/snippets.json.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(editing == nil ? .defaultAction : nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 600, height: 560)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "text.quote")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Snippets").font(.title3.weight(.semibold))
                Text(target.title.map {
                    "Type /s and a name in the message box to insert one. Turn on “Add to every message I send” to put it before each message you send \($0) from Deck."
                } ?? "Type /s and a name in a session's message box to insert one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    isNew = true
                    editing = Snippet(name: "", text: "", scope: .global)
                } label: { Label("New Snippet", systemImage: "plus") }
                    .buttonStyle(.deck(.secondary))
                    .disabled(editing != nil)
                Button { suggest() } label: { Label("Suggest from History", systemImage: "sparkles") }
                    .buttonStyle(.deck(size: .small))
                    .disabled(suggesting.isBusy)
                    .help("Claude reads what you typed to your sessions in the last 30 days and suggests snippets for what you keep repeating")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ snippets: [Snippet], everyMessage: Bool = true) -> some View {
        if !snippets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(snippets) { row($0, everyMessage: everyMessage && session != nil) }
            }
        }
    }

    private func row(_ snippet: Snippet, everyMessage: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(snippet.name).font(.callout.weight(.semibold))
                    Text(snippet.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(snippet.text).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Under the text, so its long label never squeezes the snippet's name.
                if everyMessage, let session {
                    Toggle("Add to every message I send", isOn: Binding(
                        get: { store.library.everyMessage[session]?.contains(snippet.id) == true },
                        set: { on in store.change { $0.setEveryMessage(session, snippet.id, on: on) } }))
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.caption)
                        .padding(.top, 4)
                        .help("Put this before every message you send this session from Deck")
                }
            }
            Spacer(minLength: 8)
            Button("Edit") { isNew = false; editing = snippet }
                .buttonStyle(.deck(.secondary, size: .small))
                .disabled(editing != nil)
            Button {
                store.change { $0.delete(snippet.id) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.deck(.secondary, size: .small))
                .help("Delete this snippet")
                .disabled(editing != nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panel))
    }

    @ViewBuilder private var suggestions: some View {
        switch suggesting {
        case .idle:
            EmptyView()
        case .reading, .asking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(suggesting == .reading ? "Reading what you typed in the last 30 days…" : "Claude is looking for what you keep retyping…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { suggesting = .idle }.buttonStyle(.deckBorderless)
            }
        case .done(let found, let messages):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(found.isEmpty ? "Nothing new to suggest from \(messages) messages: you don't retype much that your snippets don't cover."
                                       : "Suggested from \(messages) messages in the last 30 days")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss All") { suggesting = .idle }.buttonStyle(.deckBorderless).font(.callout)
                }
                ForEach(found) { s in
                    SnippetSuggestionCard(suggestion: s,
                                          onAdd: { store.change { $0.save(s.snippet) }; dropSuggestion(s.id) },
                                          onEdit: { isNew = true; editing = s.snippet; dropSuggestion(s.id) },
                                          onDismiss: { dropSuggestion(s.id) })
                        .disabled(editing != nil)
                }
            }
        }
    }

    /// Reads what you typed, asks Claude for snippets, and keeps the ones you really did repeat.
    private func suggest() {
        suggesting = .reading
        let existing = store.library.snippets
        Task.detached(priority: .userInitiated) {
            let messages = SnippetHistory.messages(days: 30)
            guard !messages.isEmpty else {
                await MainActor.run { suggesting = .failed("No messages you typed in the last 30 days.") }
                return
            }
            await MainActor.run { suggesting = .asking }
            let prompt = SnippetSuggestions.prompt(messages: messages, days: 30, existing: existing)
            let run = ClaudeRunner.run(ActivitySummarizer.arguments(prompt: prompt, schema: SnippetSuggestions.schema, model: "sonnet"),
                                       in: NSHomeDirectory(), timeout: 180)
            let found = (try? run.get()).flatMap { SnippetSuggestions.parse($0, messages: messages, existing: existing) }
            await MainActor.run {
                if let found { suggesting = .done(found, messages: messages.count) } else { suggesting = .failed("Couldn't reach Claude. Try again.") }
            }
        }
    }

    private func dropSuggestion(_ id: String) {
        if case .done(var found, let messages) = suggesting {
            found.removeAll { $0.id == id }
            suggesting = .done(found, messages: messages)
        }
    }

    private func editor(_ snippet: Snippet) -> some View {
        let draft = Binding(get: { editing ?? snippet }, set: { editing = $0 })
        let valid = !snippet.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New snippet" : "Edit snippet").font(.headline)
            HStack(spacing: 10) {
                Text("Name").frame(width: 60, alignment: .leading)
                TextField("short and crisp", text: draft.name).textFieldStyle(.roundedBorder)
                Text(snippet.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                Text("Text").frame(width: 60, alignment: .leading).padding(.top, 6)
                TextEditor(text: draft.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 80, maxHeight: 160)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            if let session, let title = target.title {
                HStack(spacing: 10) {
                    Text("Show in").frame(width: 60, alignment: .leading)
                    Picker("", selection: draft.scope) {
                        Text("All sessions").tag(Snippet.Scope.global)
                        Text("Only \(title)").tag(Snippet.Scope.session(session))
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                    .buttonStyle(.deck(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var s = snippet
                    s.name = s.name.trimmingCharacters(in: .whitespaces)
                    store.change { $0.save(s) }
                    editing = nil
                }
                .buttonStyle(.deck(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.accent.opacity(0.5)))
    }
}

/// Shown above a session's message box while snippets are added to every message, so it's
/// never a surprise; click to change them.
struct StandingSnippetsChip: View {
    let names: [String]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                Text("Every message starts with: ").foregroundStyle(.secondary)
                    + Text(names.joined(separator: ", ")).foregroundStyle(Theme.accent)
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3)))
        }
        .buttonStyle(.deckPlain)
        .help("These snippets are put before every message you send from Deck. Click to change.")
    }
}

private enum SnippetSuggestState: Equatable {
    case idle, reading, asking
    case done([SnippetSuggestions.Suggestion], messages: Int)
    case failed(String)

    var isBusy: Bool { self == .reading || self == .asking }
}

/// One suggested snippet: its text, why, and how often you typed it.
private struct SnippetSuggestionCard: View {
    let suggestion: SnippetSuggestions.Suggestion
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let s = suggestion
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(Theme.accent)
                Text(s.snippet.name).font(.callout.weight(.medium))
                Text(s.snippet.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.deckBorderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss this suggestion")
            }
            Text(s.snippet.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !s.why.isEmpty { Text(s.why).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("You typed this \(s.count)× in \(s.sessions) session\(s.sessions == 1 ? "" : "s")")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("“\(s.phrase)”").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(s.phrase)
            }
            HStack(spacing: 8) {
                Button("Add Snippet", action: onAdd).buttonStyle(.deck(.primary, size: .small))
                Button("Edit First…", action: onEdit).buttonStyle(.deck(size: .small))
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.accent.opacity(0.2)))
    }
}
