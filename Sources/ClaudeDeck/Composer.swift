import AppKit
import SwiftUI

struct Composer: View {
    @Environment(SessionStore.self) private var store
    @Environment(ToolboxStore.self) private var toolbox
    let session: Session
    let model: TranscriptModel
    @Binding var attachments: [Attachment]
    let onError: (String) -> Void

    @State private var draft = ""
    @State private var keyMonitor: Any?
    @State private var menuIndex = 0
    /// Esc closes the menu for the text typed so far; typing more reopens it.
    @State private var menuDismissedFor: String?
    @FocusState private var focused: Bool

    /// Typing while a dialog is open would land in the dialog, and Return would pick an option.
    private var promptOpen: Bool { session.status == .waiting }

    /// Commands matching what's typed after "/", or none when the menu shouldn't show.
    private var menuItems: [SlashCommand] {
        guard focused, let q = CommandCatalog.query(in: draft), menuDismissedFor != draft else { return [] }
        return CommandCatalog.matches(q, in: toolbox.commands)
    }

    private var canSend: Bool {
        !promptOpen && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        // The "/" menu sits directly above the message box, in the layout, so it never overlaps it.
        VStack(spacing: 8) {
            if !menuItems.isEmpty {
                SlashMenu(items: menuItems, selected: min(menuIndex, menuItems.count - 1)) { accept($0) }
            }
            inputBox
        }
        .frame(maxWidth: 816)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Text("↩ send · ⇧↩ or ⌘↩ new line · / commands · paste or drop images and files")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RemoteControlButton(session: session)
                Button { store.openTerminal(session) } label: {
                    FooterLabel(title: "Open Terminal", systemImage: "apple.terminal")
                }
                .help("Jump to this session's Ghostty terminal (⇧⌘T)")
                Button { store.requestEnd(session) } label: {
                    FooterLabel(title: "End Session", systemImage: "stop.circle")
                }
                .disabled(store.ending.contains(session.sessionId))
                .help("Quit Claude and close its terminal; you can resume it later (⇧⌘E)")
            }
            .font(.caption)
            .buttonStyle(.deckBorderless)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 816)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .onAppear {
            focusSoon()
            installKeyMonitor()
        }
        // Switching sessions (click, ⌘K, ⌘1–9, ⌥⌘↑/↓) lands you in the message box.
        .onChange(of: store.selectedId) { focusSoon() }
        .onChange(of: store.showSwitcher) { if !store.showSwitcher { focusSoon() } }
        .onChange(of: draft) { menuIndex = 0 }
        .onChange(of: store.composerInsert) {
            guard let insert = store.composerInsert else { return }
            store.composerInsert = nil
            draft = draft.isEmpty ? insert : draft + (draft.hasSuffix(" ") ? "" : " ") + insert
            focusSoon()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
        }
    }

    private var inputBox: some View {
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
                .buttonStyle(.deckPlain)
                .foregroundStyle(.secondary)
                .help("Attach images or files (you can also paste or drop them)")

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
                .buttonStyle(.deckPlain)
                .disabled(!canSend)
                .help(promptOpen ? "Answer the prompt first" : "Send (↩)")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.panel)
                .shadow(color: .black.opacity(focused ? 0.1 : 0.05), radius: focused ? 10 : 4, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    /// Handles keys before the text field sees them (it would otherwise swallow Esc and the arrows):
    /// the "/" menu's ↑/↓, Tab, Return and Esc, and ⌘V of images.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            let items = menuItems
            if !items.isEmpty && mods.isEmpty {
                let current = min(menuIndex, items.count - 1)
                switch event.keyCode {
                case 125: menuIndex = (current + 1) % items.count; return nil                 // ↓
                case 126: menuIndex = (current + items.count - 1) % items.count; return nil   // ↑
                case 48, 36, 76: accept(items[current]); return nil                          // Tab, Return
                case 53: menuDismissedFor = draft; return nil                                 // Esc
                default: break
                }
            }
            // ⌘↩ and ⇧↩ add a new line at the cursor (↩ sends, ⌥↩ is the field's own new line).
            if (event.keyCode == 36 || event.keyCode == 76) && (mods == .command || mods == .shift) {
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return nil
            }
            if mods == .command, event.charactersIgnoringModifiers == "v" {
                let pb = NSPasteboard.general
                guard AttachmentStore.shouldAttach(from: pb) else { return event }
                let found = AttachmentStore.from(pasteboard: pb)
                guard !found.isEmpty else { return event }
                attachments += found
                return nil
            }
            return event
        }
    }

    private func accept(_ command: SlashCommand) {
        draft = command.command + " "
        menuDismissedFor = nil
        focusSoon()
    }

    /// The sidebar keeps focus while it handles the selection, so take it just after.
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private var placeholder: String {
        switch session.status {
        case .busy: "Message Claude — it'll be queued until the current step finishes"
        case .waiting: "Answer the prompt above first…"
        default: "Message Claude…"
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments
        let kind = CommandCatalog.kind(of: text)
        // Commands Deck handles itself (e.g. /usage) never reach the session.
        if kind == .deck && staged.isEmpty {
            draft = ""
            store.showUsage = true
            return
        }
        // Images are pasted as attachments; other files are named by path for Claude to read.
        let images = staged.filter(\.isImage)
        let message = AttachmentStore.message(text, files: staged.filter { !$0.isImage })
        // Show the message immediately; the terminal round trip happens in the background.
        let thumbs = images.compactMap { (try? Data(contentsOf: $0.url)).flatMap { TranscriptParser.thumbnail($0) } }
        let outgoingId = model.addOutgoing(text: message, images: thumbs, whileBusy: session.status == .busy)
        draft = ""
        attachments = []
        Task {
            do {
                try await Ghostty.send(text: message, images: images.map(\.url), to: session)
                model.markDelivered(outgoingId)
                // Commands like /model or /mcp open a menu in the terminal: bring it forward.
                if kind == .terminal {
                    try? await Ghostty.focus(session)
                    HUD.show("\(text.split(separator: " ")[0]) opened in the terminal", symbol: "apple.terminal", tint: Theme.accent)
                }
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
        preview
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
                .buttonStyle(.deckPlain)
                .help("Remove")
                .padding(3)
                .opacity(hovering ? 1 : 0.85)
            }
            .onHover { hovering = $0 }
            .help(attachment.name)
    }

    @ViewBuilder private var preview: some View {
        if let image = attachment.thumbnail {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            // A file: its Finder icon and name.
            VStack(spacing: 3) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                    .resizable().frame(width: 30, height: 30)
                Text(attachment.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))
        }
    }
}

/// The "/" menu: every command you can type here, filtered as you type.
struct SlashMenu: View {
    let items: [SlashCommand]
    let selected: Int
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        Button { pick(item) } label: {
                            HStack(spacing: 10) {
                                Text(item.command)
                                    .font(.system(.callout, design: .monospaced).weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if item.kind != .send {
                                    Label(item.kind == .terminal ? "opens in terminal" : "in Deck",
                                          systemImage: item.kind == .terminal ? "apple.terminal" : "macwindow")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.accent)
                                }
                                Text(item.source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(i == selected ? Theme.accent.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.deckPlain)
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { proxy.scrollTo(items[selected].id) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.15), radius: 14, y: 4))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Connects the session with Remote Control in one click; once connected, opens it on claude.ai.
struct RemoteControlButton: View {
    @Environment(SessionStore.self) private var store
    let session: Session

    var body: some View {
        if let url = session.remoteURL {
            Button { NSWorkspace.shared.open(url) } label: {
                FooterLabel(title: "Remote Control On", systemImage: "iphone.radiowaves.left.and.right", tint: Theme.accent)
            }
            .help("Connected with Remote Control: open it on claude.ai, or in the Claude app on your phone")
            .contextMenu {
                Button("Copy Link") { Clipboard.copy(url.absoluteString) }
            }
        } else {
            Button { store.connectRemote(session) } label: {
                FooterLabel(title: "Remote Control", systemImage: "iphone.radiowaves.left.and.right")
            }
            .disabled(session.status == .busy || session.status == .waiting)
            .help(session.status == .busy || session.status == .waiting
                  ? "Available once Claude finishes this step"
                  : "Drive this session from the Claude app on your phone or claude.ai. It keeps running on this Mac.")
        }
    }
}

/// The actions under the message box: same icon slot and spacing, so they line up as one row.
struct FooterLabel: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(tint ?? .secondary)
            Text(title)
        }
    }
}
