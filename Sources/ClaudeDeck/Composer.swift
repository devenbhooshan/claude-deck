import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A session's message box: sends by typing into its terminal.
struct Composer: View {
    @Environment(SessionStore.self) private var store
    @Environment(ToolboxStore.self) private var toolbox
    let session: Session
    let model: TranscriptModel
    @Binding var attachments: [Attachment]
    let onError: (String) -> Void

    @State private var draft = ""
    @State private var refocus = 0
    private var snippets: SnippetStore { .shared }

    /// Typing while a dialog is open would land in the dialog, and Return would pick an option.
    private var promptOpen: Bool { session.status == .waiting }

    var body: some View {
        MessageBox(draft: $draft, attachments: $attachments, draftKey: session.sessionId, placeholder: placeholder,
                   canSend: !promptOpen || routed != nil,
                   commands: snippets.library.commands(for: session.sessionId) + toolbox.commands, mentions: mentions,
                   routedTo: routed?.displayTitle,
                   hint: "↩ send · ⇧↩ or ⌘↩ new line · / commands · @session to send elsewhere · paste or drop files",
                   sendHelp: routed.map { "Send to \($0.displayTitle) (↩)" } ?? (promptOpen ? "Answer the prompt first" : "Send (↩)"),
                   refocus: refocus, takesMenuCommands: true,
                   standing: snippets.library.standing(for: session.sessionId).map(\.name),
                   onStandingTap: { snippets.open(for: session) },
                   onAction: { if $0 == Snippets.manageCommand { snippets.open(for: session) } },
                   onSend: send) {
            Button { store.openTerminal(session) } label: {
                FooterLabel(title: "Open Terminal", systemImage: "apple.terminal")
            }
            .help("Jump to this session's Ghostty terminal (⇧⌘T)")
            // A background session (typed into through the window Deck attached) is stopped, not ended.
            if session.isBackground {
                Button { store.stopBackground(session) } label: {
                    FooterLabel(title: "Stop", systemImage: "stop.circle")
                }
                .disabled(store.backgroundBusy.contains(session.sessionId))
                .help("Stop this background session (claude stop); its conversation is kept")
            } else {
                Button { store.requestEnd(session) } label: {
                    FooterLabel(title: "End Session", systemImage: "stop.circle")
                }
                .disabled(store.ending.contains(session.sessionId))
                .help("Quit Claude and close its terminal; you can resume it later (⇧⌘E)")
            }
        }
        // Switching sessions (click, ⌘K, ⌘1–9, ⌥⌘↑/↓) lands you in the message box.
        .onChange(of: store.selectedId) { refocus += 1 }
        .onChange(of: store.showSwitcher) { if !store.showSwitcher { refocus += 1 } }
        .onChange(of: store.composerInsert) { takeInsert() }
        // Opened to edit a handoff: its text arrives with the session (after the saved draft loads).
        .onAppear { DispatchQueue.main.async { takeInsert() } }
    }

    private func takeInsert() {
        guard let insert = store.composerInsert else { return }
        store.composerInsert = nil
        draft = draft.isEmpty ? insert : draft + (draft.hasSuffix(" ") ? "" : " ") + insert
        refocus += 1
    }

    /// `@name message`: the other running session it goes to instead of this one.
    private var routed: Session? {
        guard let (name, _) = SessionAddress.split(draft),
              let target = SessionAddress.resolve(name, in: store.live), target.id != session.id else { return nil }
        return target
    }

    /// The other running sessions, for the menu after a leading "@".
    private var mentions: [SlashCommand] {
        store.live.filter { $0.id != session.id }.map {
            SlashCommand(command: "@" + SessionAddress.token($0.displayTitle), description: $0.status.label,
                         source: $0.sessionId == store.coordinatorId ? "Coordinator" : $0.projectName)
        }
    }

    private var placeholder: String {
        switch session.status {
        case .busy: "Message Claude — it'll be queued until the current step finishes"
        case .waiting: "Answer the prompt above first…"
        default: "Message Claude…"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments
        if let target = routed, let (_, message) = SessionAddress.split(text) {
            draft = ""
            attachments = []
            Task {
                do { try await store.send(message, attachments: staged, to: target) } catch {
                    if draft.isEmpty { draft = text }
                    attachments = staged + attachments
                    onError(error.localizedDescription)
                }
            }
            return
        }
        let kind = CommandCatalog.kind(of: text)
        // Commands Deck handles itself (e.g. /usage) never reach the session.
        if kind == .deck && staged.isEmpty {
            draft = ""
            store.showUsage = true
            return
        }
        // Images are pasted as attachments; other files are named by path for Claude to read.
        // Snippets set to go with every message come first (shown by the chip over the box).
        let images = staged.filter(\.isImage)
        let message = AttachmentStore.message(snippets.library.prepend(text, for: session.sessionId),
                                              files: staged.filter { !$0.isImage })
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

/// The message box, the same wherever you talk to Claude: a session or a routine run. Text and
/// attachments (paperclip, paste, drop), the "/" menu, ⇧↩ for a new line, and the unsent draft
/// kept under `draftKey`. Only sending differs, so that's `onSend`'s, which reads and clears
/// `draft` and `attachments`.
struct MessageBox<Footer: View>: View {
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    let draftKey: String
    let placeholder: String
    /// False while Claude can't take a message (a dialog is open, a run is working).
    var canSend = true
    var commands: [SlashCommand] = []
    /// Other sessions, offered after a leading "@".
    var mentions: [SlashCommand] = []
    /// The session an `@name` message goes to instead, shown above the box.
    var routedTo: String? = nil
    let hint: String
    var sendHelp = "Send (↩)"
    /// Changing it puts the cursor back in the box.
    var refocus = 0
    /// Takes the cursor when it appears (off where several boxes share a screen).
    var autofocus = true
    /// Answers menu commands (Attach Latest Screenshot) even when the cursor is elsewhere.
    var takesMenuCommands = false
    /// Names of the snippets put before every message, shown as a chip over the box.
    var standing: [String] = []
    var onStandingTap: () -> Void = {}
    /// Runs a "/" menu row of kind `.action` (Manage snippets…).
    var onAction: (SlashCommand) -> Void = { _ in }
    let onSend: () -> Void
    @ViewBuilder var footer: () -> Footer

    @State private var keyMonitor: Any?
    @State private var menuIndex = 0
    /// Esc closes the menu for the text typed so far; typing more reopens it.
    @State private var menuDismissedFor: String?
    /// A short note shown above the box ("No screenshots in ~/Desktop"), cleared after a moment.
    @State private var notice: String?
    @FocusState private var focused: Bool

    /// Commands matching what's typed after "/", or none when the menu shouldn't show.
    private var menuItems: [SlashCommand] {
        guard focused, menuDismissedFor != draft else { return [] }
        if let q = SessionAddress.query(in: draft) { return CommandCatalog.matches(q, in: mentions) }
        guard !commands.isEmpty, let q = CommandCatalog.query(in: draft) else { return [] }
        return CommandCatalog.matches(q, in: commands)
    }

    private var sendable: Bool {
        canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        // The "/" menu sits directly above the message box, in the layout, so it never overlaps it.
        VStack(spacing: 8) {
            if !menuItems.isEmpty {
                SlashMenu(items: menuItems, selected: min(menuIndex, menuItems.count - 1)) { accept($0) }
            }
            if let routedTo {
                Label("Sends to \(routedTo), not this session", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .help("A message starting with @\(SessionAddress.token(routedTo)) is typed into that session as you")
            }
            if !standing.isEmpty {
                StandingSnippetsChip(names: standing, open: onStandingTap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            if let notice {
                Label(notice, systemImage: "camera.viewfinder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
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
                Text(hint)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                footer()
            }
            .font(.caption)
            .buttonStyle(.deckBorderless)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 816)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .onAppear {
            let saved = Drafts.draft(for: draftKey)
            attachments = saved.files.compactMap(AttachmentStore.restore)
            // A long draft (from before this limit existed) goes in as a file, never into the box.
            if !attachLongText(saved.text) { draft = saved.text }
            if autofocus { focusSoon() }
            installKeyMonitor()
        }
        .onChange(of: refocus) { focusSoon() }
        .onChange(of: draft) { before, after in
            menuIndex = 0
            // Pasted or typed past the limit: the text becomes an attached file, like a chat app.
            if attachLongText(after) { return }
            // Dropping a file on the text types its path: attach the file instead. (Never while
            // typing or pasting, which are key presses.)
            if NSApp.currentEvent?.type != .keyDown,
               let drop = AttachmentStore.droppedFiles(old: before, new: after,
                                                       dragged: AttachmentStore.files(on: NSPasteboard(name: .drag))) {
                attachments += drop.files.compactMap(AttachmentStore.from(fileURL:))
                draft = drop.text
                return
            }
            // A screenshot's temporary path dropped or pasted from the menu: copy the file now,
            // before macOS deletes it.
            if NSApp.currentEvent?.type != .keyDown, rescueScreenshots() { return }
            Drafts.update(draftKey) { $0.text = draft }
        }
        .onChange(of: attachments) { Drafts.update(draftKey) { $0.files = attachments.map(\.url.path) } }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attachLatestScreenshot)) { _ in
            if focused || takesMenuCommands { attachLatestScreenshot() }
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
                .help("Attach images or files (you can also paste or drop them; ⌥⌘V attaches your latest screenshot)")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($focused)
                    .padding(.vertical, 5)
                    .onSubmit(send)

                Button(action: send) {
                    ZStack {
                        Circle().fill(sendable ? Theme.accent : Color.primary.opacity(0.1))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(sendable ? .white : .secondary)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.deckPlain)
                .disabled(!sendable)
                .help(sendHelp)
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

    private func send() {
        guard sendable else { return }
        _ = rescueScreenshots()
        onSend()
    }

    /// Copies screenshots whose temporary paths are in the text into Deck's cache and attaches
    /// them instead (macOS deletes those files when the thumbnail closes). True if any were.
    private func rescueScreenshots() -> Bool {
        guard draft.contains(Screenshots.tempMarker) else { return false }
        let rescued = Screenshots.rescue(draft, attach: AttachmentStore.from(fileURL:))
        guard !rescued.attached.isEmpty else { return false }
        attachments += rescued.attached
        draft = rescued.text
        return true
    }

    /// Moves text over `AttachmentStore.longTextLimit` out of the box into an attached .txt file,
    /// so the box never holds (and re-lays out) tens of thousands of characters. False if it's
    /// short, or if the file couldn't be saved (then the text stays where it was).
    private func attachLongText(_ text: String) -> Bool {
        guard AttachmentStore.isLong(text), let file = AttachmentStore.from(longText: text) else { return false }
        attachments.append(file)
        draft = ""
        // Saved now too: when it came from the saved draft, `draft` was already empty and wouldn't change.
        Drafts.update(draftKey) { $0.text = ""; $0.files = attachments.map(\.url.path) }
        show("Long text (\(text.count.formatted()) characters) attached as a file, sent with your message")
        return true
    }

    /// ⌥⌘V: the newest image in the screenshot folder (Screenshot.app's "Save to").
    private func attachLatestScreenshot() {
        let folder = Screenshots.folder()
        guard let latest = Screenshots.latest(in: folder) else {
            return show("No screenshots in \(Theme.shortPath(folder.path))")
        }
        guard let a = AttachmentStore.from(fileURL: latest) else { return show("Couldn't attach \(latest.lastPathComponent)") }
        attachments.append(a)
        focusSoon()
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if notice == text { withAnimation { notice = nil } }
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
            if mods == [.command, .option], event.charactersIgnoringModifiers == "v" {
                attachLatestScreenshot()
                return nil
            }
            if mods == .command, event.charactersIgnoringModifiers == "v" {
                let pb = NSPasteboard.general
                // A copied screenshot path: attach a copy of the file, paste the rest as text.
                if let text = pb.string(forType: .string), text.contains(Screenshots.tempMarker) {
                    let rescued = Screenshots.rescue(text, attach: AttachmentStore.from(fileURL:))
                    if !rescued.attached.isEmpty {
                        attachments += rescued.attached
                        if !rescued.text.isEmpty, let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.insertText(rescued.text, replacementRange: editor.selectedRange())
                        }
                        return nil
                    }
                }
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
        switch command.kind {
        case .snippet: draft = command.insert ?? ""   // only "/s name" was typed: the snippet replaces it
        case .action:
            draft = ""
            onAction(command)
        default: draft = command.command + " "
        }
        menuDismissedFor = nil
        focusSoon()
    }

    /// The sidebar keeps focus while it handles the selection, so take it just after.
    /// Focusing a text field selects all of it; with a saved draft you want to carry on typing, so
    /// the cursor goes to the end.
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focused = true
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }
}

extension Notification.Name {
    /// The Attach Latest Screenshot menu command, for the message box that's showing.
    static let attachLatestScreenshot = Notification.Name("ClaudeDeck.attachLatestScreenshot")
}

/// Drop images or files anywhere on the conversation to attach them.
struct AttachmentDrop: ViewModifier {
    @Binding var attachments: [Attachment]
    var enabled = true
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted && enabled {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(Theme.accent.opacity(0.06))
                        .overlay(Label("Drop images or files to attach", systemImage: "paperclip")
                            .font(.title3.weight(.medium)).foregroundStyle(Theme.accent))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                load(providers)
                return true
            }
    }

    private func load(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if let a = AttachmentStore.from(fileURL: url) { attachments.append(a) }
                    }
                }
            } else {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        if let img = NSImage(data: data), let a = AttachmentStore.from(image: img) { attachments.append(a) }
                    }
                }
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
            .frame(width: attachment.isImage ? 64 : 200, height: 64)
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
            .help(attachment.isImage ? attachment.name : "\(attachment.name): click to open")
    }

    @ViewBuilder private var preview: some View {
        if let image = attachment.thumbnail {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            // A file: its icon, name and size, like a chat app's file chip. Click to open it.
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size {
                        Text(size).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(attachment.url) }
            .background(Color.primary.opacity(0.04))
        }
    }

    private var size: String? {
        guard let bytes = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
                                if let (label, symbol) = Self.badge(item.kind) {
                                    Label(label, systemImage: symbol)
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

    /// What choosing a row does, when it isn't just typing the command.
    static func badge(_ kind: SlashCommand.Kind) -> (String, String)? {
        switch kind {
        case .send: nil
        case .terminal: ("opens in terminal", "apple.terminal")
        case .deck: ("in Deck", "macwindow")
        case .snippet: ("inserts text", "text.quote")
        case .action: ("opens", "macwindow")
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
