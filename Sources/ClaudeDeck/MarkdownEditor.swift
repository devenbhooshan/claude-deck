import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A markdown file, edited in place over the session: styled as you type, with a preview. It
/// saves as you go, follows Claude's changes to the file, and can send a passage to the session
/// with your note.
struct MarkdownEditor: View {
    let url: URL
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var state: LoadState = .loading
    @State private var preview = false
    /// The file on disk, when it changed under your unsaved edits.
    @State private var theirs: String?
    @State private var comparing = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var watcher: FileWatcher?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var asking = false
    @State private var note = ""

    enum LoadState { case loading, ready, missing, unreadable }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let theirs { conflictBar(theirs) }
            Group {
                switch state {
                case .loading:
                    ProgressView()
                case .missing:
                    ContentUnavailableView("File not found", systemImage: "doc.questionmark",
                                           description: Text(Theme.shortPath(url.path)))
                case .unreadable:
                    ContentUnavailableView("Can't read this file as text", systemImage: "doc")
                case .ready:
                    if preview {
                        MarkdownPreview(text: text, base: url.deletingLastPathComponent(), open: openLink)
                    } else {
                        MarkdownTextView(text: $text, selection: $selection, onEscape: close)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, idealWidth: 1040, minHeight: 680, idealHeight: 820)
        .background(Theme.surface)
        .background {
            // Shortcuts without buttons of their own (a hidden button's shortcut doesn't fire).
            Group {
                Button("Save") { flush() }.keyboardShortcut("s")
                Button("Preview") { if state == .ready { preview.toggle() } }.keyboardShortcut("p", modifiers: [.command, .option])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear(perform: load)
        .onDisappear {
            flush()
            watcher = nil
        }
        .onChange(of: text) { scheduleSave() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(saveError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.danger))
                        .help(saveError ?? "Saves as you type (⌘S saves now)")
                }
                Text(Theme.shortPath(url.deletingLastPathComponent().path))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Mode", selection: $preview) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .pointingHand()
            .disabled(state != .ready)
            .help("Write or preview (⌥⌘P)")
            Button { asking = true } label: {
                Label("Ask Claude", systemImage: "text.bubble")
            }
            .buttonStyle(.deck(size: .small))
            .disabled(askTarget == nil || selection.length == 0 || preview)
            .help(askHelp)
            .popover(isPresented: $asking, arrowEdge: .bottom) { askPopover }
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.deck(size: .small))
                .help("Show in Finder")
            Button { flush(); NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.deck(size: .small))
                .help("Open in \(NSWorkspace.shared.urlForApplication(toOpen: url).map { $0.deletingPathExtension().lastPathComponent } ?? "the default app")")
            Button("Done") { close() }
                .buttonStyle(.deck(.primary, size: .small))
                .keyboardShortcut(.cancelAction)
                .help("Save and close (Esc)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var status: String {
        if saveError != nil { return "Not saved" }
        if theirs != nil { return "Changed on disk" }
        return text == saved ? "Saved" : "Edited"
    }

    // MARK: - Asking Claude about a passage

    /// The session you're looking at, if it's running: where "Ask Claude" sends.
    private var askTarget: Session? { store.session(store.selectedId).flatMap { $0.isLive ? $0 : nil } }

    private var askHelp: String {
        guard let target = askTarget else { return "Open a running session to ask Claude about this file" }
        return selection.length == 0 ? "Select a passage to ask \(target.displayTitle) about it"
            : "Send the selected passage to \(target.displayTitle) with your note"
    }

    private var selected: NSRange { NSIntersectionRange(selection, NSRange(location: 0, length: (text as NSString).length)) }

    private var askPopover: some View {
        let lines = MarkdownEditing.lines(of: selected, in: text)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Ask \(askTarget?.displayTitle ?? "Claude") about \(lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)")")
                .font(.headline)
            Text((text as NSString).substring(with: selected))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(width: 3) }
            TextField("What should Claude change or explain?", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }
                    .buttonStyle(.deck(size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .buttonStyle(.deck(.primary, size: .small))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func send() {
        guard let target = askTarget else { return }
        flush() // so Claude reads what you see
        let message = MarkdownEditing.feedback(path: url.path, cwd: target.cwd, lines: MarkdownEditing.lines(of: selected, in: text),
                                               excerpt: (text as NSString).substring(with: selected), note: note)
        asking = false
        note = ""
        Task {
            do {
                try await Ghostty.send(text: message, to: target)
                HUD.show("Sent to Claude", detail: target.displayTitle, symbol: "paperplane.fill", tint: Theme.accent)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - When the file changes on disk

    private func conflictBar(_ theirs: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.waiting)
                Text("This file changed on disk while you were editing.")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(comparing ? "Hide Changes" : "Compare") { comparing.toggle() }
                    .buttonStyle(.deck(size: .small))
                    .help("What's different on disk, compared with yours")
                Button("Use Theirs") {
                    text = theirs
                    saved = theirs
                    resolve()
                }
                .buttonStyle(.deck(size: .small))
                .help("Drop your unsaved edits and take the file as it is now")
                Button("Keep Mine") {
                    resolve()
                    save()
                }
                .buttonStyle(.deck(.primary, size: .small))
                .help("Save your version over the file")
            }
            if comparing {
                ScrollView {
                    DiffView(lines: LineDiff.compact(LineDiff.diff(old: text, new: theirs)))
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.waiting.opacity(0.1))
    }

    private func resolve() {
        theirs = nil
        comparing = false
    }

    // MARK: - Loading and saving

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { state = .missing; return }
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else { state = .unreadable; return }
        text = disk
        saved = disk
        state = .ready
        watch()
    }

    /// Watches again after every change: editors and Claude often replace the file rather than
    /// write into it, which ends the old watch.
    private func watch() {
        watcher = FileWatcher(url: url, events: [.write, .rename, .delete, .extend]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { diskChanged() }
        }
    }

    private func diskChanged() {
        watch()
        // Deleted or unreadable for a moment: keep what you have.
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else { return }
        switch MarkdownEditing.diskChanged(saved: saved, current: text, disk: disk) {
        case .same:
            break
        case .reload:
            text = disk
            saved = disk
            theirs = nil
        case .conflict:
            saveTask?.cancel()
            theirs = disk
        }
    }

    private func scheduleSave() {
        guard state == .ready, theirs == nil, text != saved else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        guard state == .ready, theirs == nil, text != saved else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func flush() {
        saveTask?.cancel()
        save()
    }

    private func close() {
        flush()
        dismiss()
    }

    /// Links in the preview: files Deck shows open here; web and mail links in your browser.
    private func openLink(_ link: URL) {
        if link.isFileURL {
            guard FileLinks.kind(of: link) != nil, FileManager.default.fileExists(atPath: link.path) else { return }
            flush()
            store.viewing = ViewedFile(url: link)
        } else if let scheme = link.scheme?.lowercased(), TranscriptTextController.openableSchemes.contains(scheme) {
            NSWorkspace.shared.open(link)
        }
    }
}

// MARK: - Writing

extension NSAttributedString.Key {
    /// A line drawn as part of a block ("code" or "quote"), so the editor can draw behind it.
    static let markdownBlock = NSAttributedString.Key("deck.markdownBlock")
}

/// Styles markdown in place: the characters stay as typed, only their look changes.
enum MarkdownStyler {
    static let body = NSFont.systemFont(ofSize: 15)
    static let mono = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    /// Past this the text is left plain, so typing stays quick in very large files.
    static let limit = 400_000

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        p.paragraphSpacing = 3
        return p
    }

    static func style(_ s: NSTextStorage) {
        let full = NSRange(location: 0, length: s.length)
        s.setAttributes([.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
        guard s.length <= limit else { return }
        for span in MarkdownSyntax.spans(in: s.string) {
            let r = span.range
            switch span.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [26, 21, 18, 16, 15, 15]
                s.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold), range: r)
                let p = paragraph.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = level <= 2 ? 14 : 8
                p.paragraphSpacing = 4
                s.addAttribute(.paragraphStyle, value: p, range: r)
            case .mark, .url, .rule:
                s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            case .bold:
                add(.boldFontMask, to: s, in: r)
            case .italic:
                add(.italicFontMask, to: s, in: r)
            case .strike, .done:
                s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                 .foregroundColor: NSColor.secondaryLabelColor], range: r)
            case .code:
                s.addAttributes([.font: mono, .foregroundColor: Palette.accent,
                                 .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06)], range: r)
            case .codeBlock:
                s.addAttribute(.font, value: mono, range: r)
                s.addAttribute(.markdownBlock, value: "code", range: line(r, in: s))
            case .quote:
                s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                s.addAttribute(.markdownBlock, value: "quote", range: line(r, in: s))
            case .link, .listMarker:
                s.addAttribute(.foregroundColor, value: Palette.accent, range: r)
            case .task:
                s.addAttributes([.foregroundColor: Palette.accent, .font: mono], range: r)
            case .table:
                s.addAttribute(.font, value: mono, range: r)
            }
        }
    }

    /// The span with its line break, so a block's lines join into one run.
    private static func line(_ r: NSRange, in s: NSTextStorage) -> NSRange {
        NSMaxRange(r) < s.length ? NSRange(location: r.location, length: r.length + 1) : r
    }

    private static func add(_ trait: NSFontTraitMask, to s: NSTextStorage, in r: NSRange) {
        s.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            s.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let tv = MarkdownEditingView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.insertionPointColor = Palette.accent
        tv.typingAttributes = [.font: MarkdownStyler.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: MarkdownStyler.paragraph]
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.string = text
        tv.undoManager?.removeAllActions()
        scroll.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        // Reloaded from disk: keep the cursor about where it was.
        let at = tv.selectedRange().location
        tv.string = text
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: min(at, (text as NSString).length), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView

        init(parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            tv.needsDisplay = true
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            let range = tv.selectedRange()
            DispatchQueue.main.async { self.parent.selection = range }
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength: Int) {
            if mask.contains(.editedCharacters) { MarkdownStyler.style(storage) }
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let sel = tv.selectedRange()
                guard sel.length == 0, let edit = MarkdownEditing.newline(at: sel.location, in: tv.string) else { return false }
                MarkdownEditingView.apply(edit, to: tv)
                return true
            default:
                return false
            }
        }
    }
}

/// The text view: a centered column, code and quote blocks drawn behind the text, ⌘B ⌘I ⌘K,
/// and task boxes you can click.
private final class MarkdownEditingView: NSTextView {
    static let column: CGFloat = 760

    /// Applies an edit so it can be undone.
    static func apply(_ edit: MarkdownEditing.Edit, to tv: NSTextView) {
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        tv.textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        tv.didChangeText()
        tv.setSelectedRange(edit.selection)
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let side = max(32, (size.width - Self.column) / 2)
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: 28) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b": Self.apply(MarkdownEditing.wrap(selectedRange(), in: string, with: "**"), to: self)
        case "i": Self.apply(MarkdownEditing.wrap(selectedRange(), in: string, with: "*"), to: self)
        case "k": Self.apply(MarkdownEditing.link(selectedRange(), in: string), to: self)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if let i = character(at: event), let edit = MarkdownEditing.toggleTask(at: i, in: string) {
            Self.apply(edit, to: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let i = character(at: event), MarkdownEditing.toggleTask(at: i, in: string) != nil { NSCursor.pointingHand.set() }
    }

    /// The character under the mouse, only when it's actually on one.
    private func character(at event: NSEvent) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(.markdownBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let kind = value as? String else { return }
            var box = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { frag, _, _, _, _ in
                box = box.union(frag)
            }
            box = box.offsetBy(dx: origin.x, dy: origin.y)
            guard !box.isNull, box.intersects(rect) else { return }
            if kind == "code" {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -12, dy: 0), xRadius: Palette.Radius.medium, yRadius: Palette.Radius.medium).fill()
            } else {
                Palette.accent.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: box.minX - 14, y: box.minY + 2, width: 3, height: box.height - 4),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}

// MARK: - Preview

/// Lets the editor's own shortcuts (⌘S, ⌥⌘P) through; a web view would otherwise take them.
private final class PreviewWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if (flags == .command && key == "s") || (flags == [.command, .option] && key == "p") { return false }
        return super.performKeyEquivalent(with: event)
    }
}

private struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let base: URL
    let open: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let v = PreviewWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        context.coordinator.open = open
        var html = ""
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            html = MarkdownHTML.page(MarkdownHTML.render(text, image: image),
                                     background: css(Palette.surface), text: css(.labelColor),
                                     secondary: css(.secondaryLabelColor), accent: css(Palette.accent),
                                     fill: css(NSColor.labelColor.withAlphaComponent(0.07)))
        }
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        v.loadHTMLString(html, baseURL: base)
    }

    /// Local images are inlined, since the page can't read files itself.
    private func image(_ address: String) -> String? {
        guard !address.contains("://"),
              let file = FileLinks.resolve(address.removingPercentEncoding ?? address, cwd: base.path),
              FileLinks.kind(of: file) == .image || file.pathExtension.lowercased() == "svg",
              let data = try? Data(contentsOf: file), data.count < 20_000_000 else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func css(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "transparent" }
        return "rgba(\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255)), \(c.alphaComponent))"
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var open: (URL) -> Void
        var html = ""

        init(open: @escaping (URL) -> Void) { self.open = open }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let link = action.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            open(link)
        }
    }
}
