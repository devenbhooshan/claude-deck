import AppKit
import SwiftUI

/// Starts Claude Code in a folder: one you've used before, or any folder you pick.
struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var highlighted: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Claude session").font(.title3.weight(.semibold))
            Text("Opens a Ghostty window in the folder and starts `claude`.")
                .font(.callout).foregroundStyle(.secondary)

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
                .onTapGesture(count: 2) { start(folder) }
            }
            .frame(minHeight: 220)
            .overlay {
                if store.projectFolders.isEmpty {
                    Text("No recent folders").foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Start Claude Here"
                    if panel.runModal() == .OK, let url = panel.url { start(url.path) }
                }
                .buttonStyle(.deck(.secondary))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.deck(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Start") { if let f = highlighted { start(f) } }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(highlighted == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Theme.accent)
        .onAppear { highlighted = store.projectFolders.first }
    }

    private func start(_ folder: String) {
        dismiss()
        store.startSession(in: folder)
    }
}
