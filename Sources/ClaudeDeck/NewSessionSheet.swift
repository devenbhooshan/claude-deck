import AppKit
import SwiftUI

/// Starts Claude Code in a folder: one you've used before, or any folder you pick.
struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var highlighted: String?
    @AppStorage("newSessionRemoteControl") private var remoteControl = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Claude session").font(.title3.weight(.semibold))
            Text("Opens a Ghostty window in the folder and starts `\(Safety.newSessionCommand(remoteControl: remoteControl))`.")
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $remoteControl) {
                    Label("Remote Control", systemImage: "iphone.radiowaves.left.and.right")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointingHand()
                .help("Also drive this session from the Claude app on your phone or claude.ai. It still runs on this Mac.")
                if remoteControl {
                    TextField("Name (optional, shown in the Claude app)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if let f = highlighted { start(f) } }
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
        store.startSession(in: folder, remoteControl: remoteControl, name: name)
    }
}
