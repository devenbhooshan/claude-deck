import AppKit
import SwiftUI

struct Composer: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    let model: TranscriptModel
    @Binding var attachments: [Attachment]
    let onError: (String) -> Void

    @State private var draft = ""
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            Thumbnail(attachment: a) { attachments.removeAll { $0.id == a.id } }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 12)
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button {
                    attachments += AttachmentStore.pick()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach images (you can also paste or drop them)")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($focused)
                    .padding(.vertical, 5)
                    .onSubmit(send)

                Button(action: send) {
                    ZStack {
                        Circle().fill(canSend ? Theme.accent : Color.primary.opacity(0.1))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canSend ? .white : .secondary)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(focused ? 0.1 : 0.05), radius: focused ? 10 : 4, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
        }
        .frame(maxWidth: 816)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("↩ send · ⌥↩ new line · paste or drop images")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .onAppear {
            focusSoon()
            installPasteMonitor()
        }
        // Switching sessions (click, ⌘K, ⌘1–9, ⌥⌘↑/↓) lands you in the message box.
        .onChange(of: store.selectedId) { focusSoon() }
        .onChange(of: store.showSwitcher) { if !store.showSwitcher { focusSoon() } }
        .onDisappear {
            if let m = pasteMonitor { NSEvent.removeMonitor(m) }
        }
    }

    /// The sidebar keeps focus while it handles the selection, so take it just after.
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private var placeholder: String {
        switch session.status {
        case .busy: "Message Claude — it'll be queued until the current step finishes"
        case .waiting: "Reply to Claude…"
        default: "Message Claude…"
        }
    }

    /// ⌘V with an image on the clipboard attaches it instead of pasting text.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pb = NSPasteboard.general
            guard AttachmentStore.shouldAttach(from: pb) else { return event }
            let found = AttachmentStore.from(pasteboard: pb)
            guard !found.isEmpty else { return event }
            attachments += found
            return nil
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments
        // Show the message immediately; the terminal round trip happens in the background.
        let thumbs = staged.compactMap { (try? Data(contentsOf: $0.url)).flatMap { TranscriptParser.thumbnail($0) } }
        let outgoingId = model.addOutgoing(text: text, images: thumbs)
        draft = ""
        attachments = []
        Task {
            do {
                try await Ghostty.send(text: text, images: staged.map(\.url), to: session)
                model.markDelivered(outgoingId)
            } catch {
                model.removeOutgoing(outgoingId)
                if draft.isEmpty { draft = text }
                attachments = staged + attachments
                onError(error.localizedDescription)
            }
        }
    }
}

private struct Thumbnail: View {
    let attachment: Attachment
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: attachment.thumbnail)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(.separator))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .padding(3)
                .opacity(hovering ? 1 : 0.85)
            }
            .onHover { hovering = $0 }
    }
}
