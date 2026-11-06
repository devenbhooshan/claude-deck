import AppKit
import SwiftUI

/// Starts Claude Code in a folder: one you've used before, or any folder you pick. With `forking`,
/// it starts a fork of that session instead, in its folder, with the same options.
struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var forking: Session? = nil
    @State private var highlighted: String?
    @AppStorage("newSessionRemoteControl") private var remoteControl = false
    @State private var name = ""

    /// Where it starts: the forked session's folder, or the one picked.
    private var folder: String? { forking?.cwd ?? highlighted }

    private var launch: SessionLaunch { SessionLaunch(name: name, remoteControl: remoteControl) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(forking.map { "Fork \u{201C}\($0.displayTitle)\u{201D}" } ?? "New Claude session")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(forking == nil
                 ? "Opens a Ghostty window in the folder and starts `\(Safety.launchCommand(launch) ?? "claude")`."
                 : "Opens a Ghostty window in \(Theme.shortPath(forking!.cwd)) with a copy of this conversation. The original carries on unchanged.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if forking == nil { folders }

            VStack(alignment: .leading, spacing: 8) {
                TextField(forking == nil ? "Name (optional)" : "Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(start)
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
                if forking == nil {
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.prompt = "Start Claude Here"
                        if panel.runModal() == .OK, let url = panel.url { start(in: url.path) }
                    }
                    .buttonStyle(.deck(.secondary))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.deck(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(forking == nil ? "Start" : "Fork", action: start)
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Theme.accent)
        .onAppear {
            highlighted = store.projectFolders.first
            if let forking { name = "Fork of \(forking.displayTitle)" }
        }
    }

    private var folders: some View {
        List(store.projectFolders, id: \.self, selection: $highlighted) { folder in
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
        .overlay {
            if store.projectFolders.isEmpty {
                Text("No recent folders").foregroundStyle(.tertiary)
            }
        }
    }

    private func start() {
        if let folder { start(in: folder) }
    }

    private func start(in folder: String) {
        dismiss()
        store.startSession(in: folder, launch, forking: forking)
    }
}
