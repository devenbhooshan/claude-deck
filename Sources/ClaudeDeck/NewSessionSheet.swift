import AppKit
import SwiftUI

/// Starts Claude Code in a folder: one you've used before, or any folder you pick. With `forking`,
/// it starts a fork of that session instead (in its folder unless you pick another), with the same options.
struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var forking: Session? = nil
    @State private var highlighted: String?
    @AppStorage("newSessionRemoteControl") private var remoteControl = false
    @State private var name = ""
    @FocusState private var listFocused: Bool

    /// A fork starts in the original's folder unless you pick another.
    private var folderChoices: [String] {
        guard let cwd = forking?.cwd else { return store.projectFolders }
        return [cwd] + store.projectFolders.filter { $0 != cwd }
    }

    /// A fork is named after the original unless you type a name.
    private var defaultName: String { forking.map { "Fork of \($0.displayTitle)" } ?? "" }
    private var launch: SessionLaunch {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return SessionLaunch(name: typed.isEmpty ? defaultName : typed, remoteControl: remoteControl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(forking.map { "Fork \u{201C}\($0.displayTitle)\u{201D}" } ?? "New Claude session")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(forking == nil
                 ? "Opens a Ghostty window in the folder and starts `\(Safety.launchCommand(launch) ?? "claude")`."
                 : "Opens a Ghostty window in the folder with a copy of this conversation. The original carries on unchanged.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            folders

            VStack(alignment: .leading, spacing: 10) {
                // A labelled row, like Remote Control below; the name shown when you leave it empty
                // is the placeholder.
                HStack(spacing: 10) {
                    Label("Name", systemImage: "character.cursor.ibeam")
                        .fixedSize()
                    TextField("", text: $name, prompt: Text(forking == nil ? "Optional" : defaultName))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(start)
                }
                .help("Shown in Deck, in /resume and, with Remote Control, in the Claude app")
                Toggle(isOn: $remoteControl) {
                    Label("Remote Control", systemImage: "iphone.radiowaves.left.and.right")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointingHand()
                .help("Also drive this session from the Claude app on your phone or claude.ai. It still runs on this Mac.")
            }

            HStack {
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = forking == nil ? "Start Claude Here" : "Fork Here"
                    if panel.runModal() == .OK, let url = panel.url { start(in: url.path) }
                }
                .buttonStyle(.deck(.secondary))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.deck(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(forking == nil ? "Start" : "Fork", action: start)
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(highlighted == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Theme.accent)
        .onAppear {
            highlighted = folderChoices.first
            // Start on the folder list, not with the name field's text selected.
            listFocused = true
        }
    }

    private var folders: some View {
        ScrollViewReader { proxy in
        List(folderChoices, id: \.self, selection: $highlighted) { folder in
            VStack(alignment: .leading, spacing: 1) {
                Text((folder as NSString).lastPathComponent).font(.body)
                Text(Theme.shortPath(folder)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .pointingHand()
            .tag(folder)
        }
        // The list's own double-click (and Return): a tap gesture on the row would swallow
        // the single click that selects it.
        .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { folders in
            if let f = folders.first { start(in: f) }
        })
        .frame(minHeight: 220)
        .focused($listFocused)
        .overlay {
            if folderChoices.isEmpty {
                Text("No recent folders").foregroundStyle(.tertiary)
            }
        }
        // The selected folder is always in view.
        .onAppear { if let h = folderChoices.first { proxy.scrollTo(h) } }
        }
    }

    private func start() {
        if let highlighted { start(in: highlighted) }
    }

    private func start(in folder: String) {
        dismiss()
        store.startSession(in: folder, launch, forking: forking)
    }
}
