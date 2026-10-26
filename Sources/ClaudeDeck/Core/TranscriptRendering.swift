import AppKit

enum ToolStyle {
    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "Skill": "wand.and.stars"
        case "TodoWrite": "checklist"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        // "mcp__server__tool" → "tool". components(separatedBy:) is never empty.
        return name.components(separatedBy: "__").last!
    }
}

struct TranscriptContent {
    let blocks: [TranscriptBlock]
    let results: [String: ToolResult]
    let queued: [String]
    let outgoing: [OutgoingMessage]
    let cwd: String
    let status: SessionStatus
    let openToolId: String?
    let loaded: Bool
    /// Text of a message to scroll to and point out once (from search).
    var focus: String? = nil
    /// There's earlier history in the file than what's shown; it loads as you scroll up.
    var hasEarlier = false

    /// Cheap fingerprint so the text is only rebuilt when something visible changed.
    var signature: String {
        "\(blocks.count)|\(blocks.first?.id ?? "")|\(hasEarlier)|\(blocks.last?.id ?? "")|\(lastToolCount)|\(results.count)|\(queued.joined(separator: "\u{1}"))|"
            + "\(outgoing.map { "\($0.id)\($0.delivered)" }.joined())|\(status)|\(openToolId ?? "")|\(loaded)|\(focus ?? "")"
    }

    private var lastToolCount: Int {
        if case .tools(let calls)? = blocks.last { return calls.count }
        return 0
    }
}

// MARK: - Text view

class TranscriptTextController: NSObject, NSTextViewDelegate {
    /// Schemes a click in the transcript may open. Links come from Claude's output, so anything
    /// that could launch an app or open a local file (file://, custom schemes) is ignored.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    private let openURL: (URL) -> Bool
    private let openFile: (URL) -> Void

    /// `openURL` opens an allowed link; the app passes NSWorkspace, tests pass a recorder.
    /// `openFile` shows a PDF, image or web page in Deck's viewer.
    init(openURL: @escaping (URL) -> Bool, openFile: @escaping (URL) -> Void = { _ in }) {
        self.openURL = openURL
        self.openFile = openFile
    }

    /// Builds the scroll view + text view pair this controller drives.
    func makeScrollView() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = ColumnTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        tv.delegate = self

        let scroll = PinnedScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tv
        // macOS pads scroll views for the title bar automatically; SwiftUI already lays us out below it,
        // and the extra inset made "scroll to bottom" stop 48pt short.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            scroll.setContentHuggingPriority(.defaultLow, for: axis)
            scroll.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        self.textView = tv
        // Only real scrolling (trackpad, wheel, scroller) decides whether to keep following new messages;
        // re-layout also moves the clip view, and must not count.
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(TranscriptTextController.userScrolled),
                                                   name: name, object: scroll)
        }
        tv.onColumnChange = { [weak self] in self?.render(force: true) }
        return scroll
    }

    weak var textView: ColumnTextView?
    var content: TranscriptContent?
    /// Called when you scroll to the top and there's earlier history to load.
    var onReachTop: (() -> Void)?
    private var firstBlockId: String?
    private var expanded: Set<String> = []
    private var lastSignature = ""
    /// True while you're at the bottom; new content keeps you there. Scrolling up turns it off.
    private var pinned = true
    private var outgoingCount = 0
    private var focused: String?

    /// Which conversation this is (the session id), so your reading place survives switching away.
    var placeKey: String?
    /// Where you were reading in each conversation you'd scrolled up in: the text around the top
    /// line, where in that text the line starts, and how far down the line the view began.
    /// Absent: you were at the bottom, following new messages.
    nonisolated(unsafe) static var places: [String: (text: String, lead: Int, offset: CGFloat)] = [:]
    private var restored = false
    /// Back at a remembered place: held through re-layouts (width settling, messages loading)
    /// until you scroll yourself.
    private var anchored = false

    @objc func userScrolled() {
        let scroll = textView?.enclosingScrollView
        pinned = isAtBottom(scroll)
        anchored = false
        savePlace()
        if content?.hasEarlier == true, let scroll, scroll.contentView.bounds.minY < 300 { onReachTop?() }
    }

    private func savePlace() {
        guard let key = placeKey, let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer,
              let scroll = tv.enclosingScrollView else { return }
        let text = tv.string as NSString
        guard !pinned, text.length > 0 else { Self.places[key] = nil; return }
        let top = scroll.contentView.bounds.minY - tv.textContainerOrigin.y
        var line = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: container),
                                           effectiveRange: &line)
        let char = layout.characterIndexForGlyph(at: line.location)
        // Text on both sides of the line's start, so it's found again even if it's short.
        let start = max(0, char - 60)
        let around = text.substring(with: NSRange(location: start, length: min(text.length, char + 60) - start))
        Self.places[key] = (around, char - start, top - rect.minY)
    }

    /// Back in a conversation you'd scrolled up in: the same line at the top again (new messages
    /// may have arrived below, and the text may wrap differently). False when there's no place.
    private func restorePlace() -> Bool {
        guard let key = placeKey, let place = Self.places[key], let tv = textView, let layout = tv.layoutManager,
              let container = tv.textContainer, let scroll = tv.enclosingScrollView else { return false }
        let found = (tv.string as NSString).range(of: place.text)
        guard found.location != NSNotFound else { return false }
        layout.ensureLayout(for: container)
        tv.sizeToFit()
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: found.location + place.lead), effectiveRange: nil)
        let y = min(rect.minY + tv.textContainerOrigin.y + place.offset, max(0, tv.frame.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        pinned = false
        anchored = true
        return true
    }

    /// Scrolls after the text view has resized to its laid-out text, so the last line is fully visible.
    private func scrollToBottom() {
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return }
        if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
        tv.sizeToFit()
        let clip = scroll.contentView
        let y = max(0, tv.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    func render(force: Bool) {
        guard let tv = textView, let content, tv.columnWidth > 100 else { return }
        // Sending a message always jumps to the bottom, even if you'd scrolled up to read.
        if content.outgoing.count > outgoingCount { pinned = true }
        // Back from a message opened by search: follow the latest again.
        if content.focus == nil, focused != nil {
            focused = nil
            pinned = true
        }
        outgoingCount = content.outgoing.count
        let signature = content.signature + "|\(expanded.sorted().joined())|\(Int(tv.columnWidth))"
        if !force && signature == lastSignature { return }
        lastSignature = signature

        let scroll = tv.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin ?? .zero
        let selection = tv.selectedRange()
        // Earlier history was added above: keep what you're reading where it is.
        let prepended = firstBlockId != nil && content.blocks.first?.id != firstBlockId
        let fromBottom = tv.frame.height - origin.y
        firstBlockId = content.blocks.first?.id

        let text = TranscriptRenderer(width: tv.columnWidth, cwd: content.cwd, expanded: expanded).render(content)
        tv.textStorage?.setAttributedString(text)
        if selection.length > 0, NSMaxRange(selection) <= text.length { tv.setSelectedRange(selection) }

        // The first time the conversation shows: back to where you were reading, if anywhere
        // (unless it was opened from search, which shows the message you searched for).
        if !restored, content.loaded, !content.blocks.isEmpty {
            restored = true
            _ = content.focus == nil && restorePlace()
        }
        if anchored, !pinned, restorePlace() {
            // Layout can still settle after this pass; stay on the same line.
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    if self?.anchored == true { _ = self?.restorePlace() }
                }
            }
            return
        }
        if pinned {
            scrollToBottom()
            // Layout can still settle (width pin, attachments) after this pass; follow it.
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    if self?.pinned == true { self?.scrollToBottom() }
                }
            }
        } else if let scroll {
            var to = origin
            if prepended, let container = tv.textContainer {
                tv.layoutManager?.ensureLayout(for: container)
                tv.sizeToFit()
                to.y = max(0, tv.frame.height - fromBottom)
            }
            scroll.contentView.scroll(to: to)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let focus = content.focus, focus != focused, let range = Self.range(of: focus, in: text.string) {
            // Opened from search: show that message and point it out, once.
            focused = focus
            pinned = false
            if let container = tv.textContainer, let layout = tv.layoutManager, let scroll {
                layout.ensureLayout(for: container)
                tv.sizeToFit()
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                // A little room above it, so it doesn't sit flush against the top.
                let y = max(0, min(rect.minY + tv.textContainerInset.height - 60, tv.frame.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            tv.showFindIndicator(for: range)
        }
    }

    /// The text you searched for: where a message starts in the rendered transcript (its first
    /// words, whatever the line breaks).
    static func range(of message: String, in text: String) -> NSRange? {
        let words = message.split { $0.isWhitespace }.prefix(8).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let re = try? NSRegularExpression(pattern: words.joined(separator: "\\s+"), options: [.caseInsensitive]) else { return nil }
        let r = re.rangeOfFirstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return r.location == NSNotFound ? nil : r
    }

    private func isAtBottom(_ scroll: NSScrollView?) -> Bool {
        guard let scroll, let doc = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= doc.bounds.height - 40
    }

    /// An image in a message: its thumbnail carries a link to the full image.
    func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let storage = textView.textStorage, charIndex < storage.length,
              let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) else { return }
        _ = self.textView(textView, clickedOnLink: link, at: charIndex)
    }

    /// Tool rows are links (deck://tool/<id>); clicking one expands or collapses it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if url == TranscriptRenderer.earlierLink {
            onReachTop?()
            return true
        }
        if url.scheme == "deck", url.host == "tool" {
            let id = url.lastPathComponent
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            render(force: true)
            return true
        }
        if let file = FileLinks.file(for: url, cwd: content?.cwd ?? "") {
            openFile(file)
        } else if let scheme = url.scheme?.lowercased(), Self.openableSchemes.contains(scheme) {
            _ = openURL(url)
        }
        return true
    }
}
/// Keeps the text view exactly as wide as the visible area, so the column can't drift off-screen.
final class PinnedScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let doc = documentView else { return }
        let width = contentView.bounds.width
        if abs(doc.frame.width - width) > 0.5 {
            doc.setFrameSize(NSSize(width: width, height: doc.frame.height))
        }
    }
}

/// Centers a fixed-width reading column and re-renders when its width changes.
final class ColumnTextView: NSTextView {
    static let maxColumn: CGFloat = 760
    var onColumnChange: (() -> Void)?
    private(set) var columnWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = max(28, (newSize.width - Self.maxColumn) / 2)
        if textContainerInset.width != inset {
            textContainerInset = NSSize(width: inset, height: 24)
        }
        let column = newSize.width - inset * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2
        if abs(column - columnWidth) > 1 {
            columnWidth = column
            DispatchQueue.main.async { [weak self] in self?.onColumnChange?() }
        }
    }
}

// MARK: - Rendering

/// A text block with rounded corners (NSTextBlock only draws square backgrounds).
final class RoundedTextBlock: NSTextBlock {
    var radius: CGFloat = Palette.Radius.medium
    var fill: NSColor = .clear
    var stroke: NSColor?
    var dashed = false

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        let rect = NSRect(
            x: frameRect.minX + width(for: .margin, edge: .minX),
            y: frameRect.minY + width(for: .margin, edge: .minY),
            width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
            height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY))
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

struct TranscriptRenderer {
    let width: CGFloat
    let cwd: String
    let expanded: Set<String>

    private static let bodyFont = NSFont.systemFont(ofSize: 13.5)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var body: NSFont { Self.bodyFont }
    private var mono: NSFont { Self.monoFont }
    private var accent: NSColor { Palette.accent }
    /// Claude's text and cards are indented past the ✦ marker.
    private var indent: CGFloat { 28 }

    func render(_ c: TranscriptContent) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if c.hasEarlier {
            let more = notice("↑ Earlier messages load as you scroll up", symbol: nil, color: .tertiaryLabelColor)
            let row = NSMutableAttributedString(attributedString: more)
            row.addAttributes([.link: Self.earlierLink, .toolTip: "Load earlier messages"],
                              range: NSRange(location: 0, length: row.length - 1))
            out.append(row)
        }
        for block in c.blocks {
            switch block {
            case .tools(let calls):
                out.append(tools(calls, c))
            case .item(let item):
                switch item.kind {
                case let .user(text, images): out.append(bubble(text, images: images))
                case .command(let cmd): out.append(command(cmd))
                case .assistant(let text): out.append(assistant(text))
                case .notice(let text): out.append(notice(text, symbol: nil, color: .secondaryLabelColor))
                case .commandOutput(let text): out.append(codeBlock(text, spacingBefore: 12))
                case .recap(let text): out.append(recap(text))
                case let .taskEvent(text, ok):
                    out.append(notice(text, symbol: ok ? "✓" : "✗", color: ok ? Palette.success : Palette.danger))
                case .tool: break
                }
            }
        }
        for q in c.queued {
            out.append(bubble(q, images: [], caption: "Queued until Claude finishes its current step", dashed: true))
        }
        for o in c.outgoing {
            out.append(bubble(o.text, images: o.images, caption: o.delivered ? "Sent" : "Sending…"))
        }
        if c.loaded && out.length == 0 {
            out.append(notice("No messages yet", symbol: nil, color: .tertiaryLabelColor))
        }
        Self.linkify(out, cwd: c.cwd)
        return out
    }

    // MARK: Pieces

    private func paragraph(_ configure: (NSMutableParagraphStyle) -> Void) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        p.paragraphSpacing = 6
        configure(p)
        return p
    }

    /// Your message: a rounded bubble sized to its text, on the right.
    private func bubble(_ text: String, images: [NSImage], caption: String? = nil, dashed: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let maxWidth = (width * 0.75).rounded()
        let padH: CGFloat = 14, padV: CGFloat = 9

        let content = NSMutableAttributedString()
        if !images.isEmpty {
            let size = images.count == 1 ? NSSize(width: 240, height: 160) : NSSize(width: 120, height: 90)
            for (i, img) in images.enumerated() {
                let att = NSTextAttachment()
                att.image = Self.rounded(img, fitting: size)
                att.bounds = NSRect(origin: .zero, size: att.image!.size)
                let thumb = NSMutableAttributedString(attachment: att)
                if let file = (img as? TranscriptImage)?.file {
                    // Click to see it full size.
                    thumb.addAttributes([.link: FileLinks.link(to: file.path), .toolTip: "Click to view full size"],
                                        range: NSRange(location: 0, length: thumb.length))
                }
                content.append(thumb)
                if i < images.count - 1 { content.append(NSAttributedString(string: " ")) }
            }
            if !text.isEmpty { content.append(NSAttributedString(string: "\n")) }
        }
        content.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: NSColor.labelColor]))

        let measured = content.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        let contentWidth = min(maxWidth, ceil(measured) + 4)

        let block = RoundedTextBlock()
        block.radius = Palette.Radius.large
        block.fill = dashed ? .clear : accent.withAlphaComponent(0.13)
        block.stroke = dashed ? accent.withAlphaComponent(0.5) : nil
        block.dashed = dashed
        block.setContentWidth(contentWidth, type: .absoluteValueType)
        block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(max(0, width - contentWidth - padH * 2), type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .minY)

        let style = paragraph { p in
            p.textBlocks = [block]
            p.paragraphSpacing = 0
        }
        content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: body]))

        if let caption {
            out.append(NSAttributedString(string: caption + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph { $0.alignment = .right; $0.paragraphSpacingBefore = 3 },
            ]))
        }
        return out
    }

    private func command(_ cmd: String) -> NSAttributedString {
        let text = cmd.hasPrefix("/") ? cmd : "/" + cmd
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: accent,
            .paragraphStyle: paragraph { $0.alignment = .right; $0.paragraphSpacingBefore = 14 },
        ])
    }

    private func notice(_ text: String, symbol: String?, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = paragraph { $0.alignment = .center; $0.paragraphSpacingBefore = 12 }
        if let symbol {
            out.append(NSAttributedString(string: symbol + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        out.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]))
        return out
    }

    /// Claude Code's "※ recap": a muted paragraph, indented like Claude's replies.
    private func recap(_ text: String) -> NSAttributedString {
        let style = paragraph { s in
            s.headIndent = indent
            s.firstLineHeadIndent = 0
            s.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            s.paragraphSpacingBefore = 16
        }
        let out = NSMutableAttributedString(string: "※\t", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
        ])
        out.append(NSAttributedString(string: "Recap  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]))
        out.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]))
        return out
    }

    /// Claude's reply: ✦ marker, then markdown blocks indented past it.
    private func assistant(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // One text block per open quote, shared by its paragraphs so the bar runs unbroken.
        var quotes: [NSTextBlock] = []
        for (i, block) in Markdown.parse(text).enumerated() {
            let first = i == 0
            while quotes.count > block.quoteDepth { quotes.removeLast() }
            while quotes.count < block.quoteDepth { quotes.append(quoteBlock(depth: quotes.count)) }
            // Inside a quote, indents are measured from the quote's text.
            let base = (quotes.isEmpty ? indent : 0) + CGFloat(max(block.listDepth - 1, 0)) * 20
            let textIndent = base + (block.listDepth > 0 ? 20 : 0)
            let color: NSColor = quotes.isEmpty ? .labelColor : .secondaryLabelColor
            let spacingBefore: CGFloat = first ? 16 : block.listDepth > 0 ? 2 : 6
            // The ✦ starts the first line when the reply opens with plain text; otherwise it sits above.
            let inlineMarker = first && quotes.isEmpty && block.listDepth == 0
            switch block.kind {
            case .paragraph(let p), .heading(let p, _):
                var font = body
                var heading = false
                if case .heading(_, let level) = block.kind {
                    font = NSFont.systemFont(ofSize: level == 1 ? 17 : 14.5, weight: .semibold)
                    heading = true
                }
                let style = paragraph { s in
                    s.headIndent = textIndent
                    s.firstLineHeadIndent = inlineMarker ? 0 : block.marker != nil ? base : textIndent
                    s.tabStops = [NSTextTab(textAlignment: .left, location: inlineMarker ? indent : textIndent)]
                    s.paragraphSpacingBefore = heading ? (first ? 16 : 10) : spacingBefore
                    s.textBlocks = quotes
                }
                if first && !inlineMarker { out.append(marker()) }
                if inlineMarker {
                    out.append(NSAttributedString(string: "✦\t", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: accent, .paragraphStyle: style,
                    ]))
                }
                if let m = block.marker {
                    out.append(NSAttributedString(string: m + "\t", attributes: [
                        .font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
                    ]))
                }
                let inline = Self.styled(p, font: font, color: color)
                inline.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: inline.length))
                // Lines after the first (e.g. "Sep 2026: 11,900" under "Sep 2025: 950") line up with
                // the text, not with the ✦ or list marker.
                let firstBreak = (inline.string as NSString).range(of: "\n")
                if firstBreak.location != NSNotFound {
                    let rest = paragraph { s in
                        s.headIndent = textIndent
                        s.firstLineHeadIndent = textIndent
                        s.paragraphSpacingBefore = 4
                        s.textBlocks = quotes
                    }
                    let start = firstBreak.location + 1
                    inline.addAttribute(.paragraphStyle, value: rest, range: NSRange(location: start, length: inline.length - start))
                }
                out.append(inline)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            case .code(let code):
                if first { out.append(marker()) }
                out.append(codeBlock(code, spacingBefore: first ? 0 : 6))
            case .table(let rows):
                if first { out.append(marker()) }
                out.append(table(rows))
            case .rule:
                if first { out.append(marker()) }
                out.append(rule())
            }
        }
        return out
    }

    /// The bar beside quoted text; a quote inside a quote (depth 1+) sits right next to its parent's bar.
    private func quoteBlock(depth: Int) -> NSTextBlock {
        let block = NSTextBlock()
        // Text blocks need an explicit width, or their text wraps after every letter.
        block.setContentWidth(width - indent - CGFloat(depth + 1) * 15, type: .absoluteValueType)
        block.setWidth(depth > 0 ? 0 : indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(accent.withAlphaComponent(0.55), for: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    /// A thin line across the reply (`---`).
    private func rule() -> NSAttributedString {
        let block = NSTextBlock()
        block.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(NSColor.separatorColor, for: .maxY)
        block.setContentWidth(width - indent, type: .absoluteValueType)
        let style = paragraph { $0.textBlocks = [block]; $0.paragraphSpacing = 0; $0.lineSpacing = 0 }
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: style])
    }

    /// A lone ✦ line, used when a reply starts with a code block or table.
    private func marker() -> NSAttributedString {
        NSAttributedString(string: "✦\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: accent,
            .paragraphStyle: paragraph { $0.paragraphSpacingBefore = 16 },
        ])
    }

    private func codeBlock(_ code: String, spacingBefore: CGFloat) -> NSAttributedString {
        let block = RoundedTextBlock()
        block.fill = NSColor.labelColor.withAlphaComponent(0.05)
        block.radius = Palette.Radius.medium
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setContentWidth(width - indent - 20, type: .absoluteValueType)
        block.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = paragraph { $0.textBlocks = [block]; $0.paragraphSpacing = 0; $0.lineSpacing = 1.5 }
        return NSAttributedString(string: code + "\n", attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
    }

    func table(_ rows: [[AttributedString]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return out }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(width - indent, type: .absoluteValueType)
        table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)

        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor.separatorColor)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 { cell.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
                let style = paragraph { $0.textBlocks = [cell]; $0.paragraphSpacing = 0 }
                let font = r == 0 ? NSFont.systemFont(ofSize: 12.5, weight: .semibold) : NSFont.systemFont(ofSize: 12.5)
                let cellText = Self.styled(c < row.count ? row[c] : AttributedString(), font: font, color: .labelColor)
                cellText.append(NSAttributedString(string: "\n"))
                cellText.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cellText.length))
                out.append(cellText)
            }
        }
        return out
    }

    /// A run of tool calls: one card, one line per call; click a line to expand it.
    private func tools(_ calls: [ToolCall], _ c: TranscriptContent) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let card = RoundedTextBlock()
        card.fill = NSColor.labelColor.withAlphaComponent(0.035)
        card.stroke = NSColor.labelColor.withAlphaComponent(0.07)
        card.radius = Palette.Radius.medium
        card.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        card.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        card.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
        card.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
        card.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        card.setContentWidth(width - indent - 20, type: .absoluteValueType)
        card.setWidth(10, type: .absoluteValueType, for: .margin, edge: .minY)
        let inner = width - indent - 20

        for call in calls {
            let result = c.results[call.id]
            let url = URL(string: "deck://tool/\(call.id)")!
            let rowStyle = paragraph { s in
                s.textBlocks = [card]
                s.tabStops = [NSTextTab(textAlignment: .left, location: 22), NSTextTab(textAlignment: .right, location: inner)]
                s.lineBreakMode = .byTruncatingTail
                s.paragraphSpacing = 3
            }
            let line = NSMutableAttributedString()
            if let icon = NSImage(systemSymbolName: ToolStyle.symbol(call.name), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
                let att = NSTextAttachment()
                att.image = Self.tinted(icon, .secondaryLabelColor)
                att.bounds = NSRect(x: 0, y: -1.5, width: icon.size.width, height: icon.size.height)
                line.append(NSAttributedString(attachment: att))
            }
            line.append(NSAttributedString(string: "\t" + ToolStyle.displayName(call.name) + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor,
            ]))
            let firstLine = (call.summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
                .replacingOccurrences(of: cwd + "/", with: "")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let more = call.summary.contains("\n") ? " ⏎…" : ""
            if let purpose = call.purpose {
                // What it's for, in words; the command itself shows on hover and when expanded.
                line.append(NSAttributedString(string: String(purpose.prefix(120)), attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            } else {
                line.append(NSAttributedString(string: String(firstLine.prefix(120)) + more, attributes: [
                    .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            if let diff = call.diff {
                let (added, removed) = LineDiff.stats(diff)
                line.append(NSAttributedString(string: "  +\(added)", attributes: [.font: mono, .foregroundColor: Palette.success]))
                line.append(NSAttributedString(string: " −\(removed)", attributes: [.font: mono, .foregroundColor: Palette.danger]))
            }
            line.append(NSAttributedString(string: "\t"))
            line.append(status(call, result, c))
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: rowStyle, range: NSRange(location: 0, length: line.length))
            line.addAttribute(.link, value: url, range: NSRange(location: 0, length: line.length - 1))
            if call.purpose != nil {
                line.addAttribute(.toolTip, value: String(call.summary.prefix(600)), range: NSRange(location: 0, length: line.length - 1))
            }
            out.append(line)

            if expanded.contains(call.id) {
                let detailStyle = paragraph { s in
                    s.textBlocks = [card]
                    s.headIndent = 22
                    s.firstLineHeadIndent = 22
                    s.paragraphSpacing = 6
                    s.lineSpacing = 1
                }
                let small = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                out.append(NSAttributedString(string: call.summary + "\n", attributes: [
                    .font: small, .foregroundColor: NSColor.labelColor, .paragraphStyle: detailStyle,
                ]))
                if let diff = call.diff { out.append(diffLines(diff, in: card, width: inner)) }
                if let result {
                    var text = result.text.isEmpty ? "(no output)" : result.text
                    if text.count > 6000 { text = String(text.prefix(6000)) + "\n… (truncated)" }
                    out.append(NSAttributedString(string: text + "\n", attributes: [
                        .font: small,
                        .foregroundColor: result.isError ? Palette.danger : NSColor.secondaryLabelColor,
                        .paragraphStyle: detailStyle,
                    ]))
                }
            }
        }
        return out
    }

    /// A diff inside a tool card: one full-width tinted row per line, with +/− gutters.
    func diffLines(_ diff: [DiffLine], in card: NSTextBlock, width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for line in diff {
            let row = RoundedTextBlock()
            row.radius = 0
            let (fill, mark, color): (NSColor, String, NSColor) = switch line.kind {
            case .added: (Palette.success.withAlphaComponent(0.14), "+", NSColor.labelColor)
            case .removed: (Palette.danger.withAlphaComponent(0.12), "−", NSColor.labelColor)
            case .context: (.clear, " ", NSColor.secondaryLabelColor)
            case .gap: (.clear, " ", NSColor.tertiaryLabelColor)
            }
            row.fill = fill
            row.setContentWidth(max(40, width - 22 - 12), type: .absoluteValueType)
            row.setWidth(22, type: .absoluteValueType, for: .margin, edge: .minX)
            row.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
            row.setWidth(1, type: .absoluteValueType, for: .padding, edge: .minY)
            row.setWidth(1, type: .absoluteValueType, for: .padding, edge: .maxY)
            let style = paragraph { s in
                s.textBlocks = [card, row]
                s.paragraphSpacing = 0
                s.lineSpacing = 0
                s.lineBreakMode = .byCharWrapping
            }
            out.append(NSAttributedString(string: "\(mark) \(line.text)\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        return out
    }

    private func status(_ call: ToolCall, _ result: ToolResult?, _ c: TranscriptContent) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        if let result {
            return NSAttributedString(string: result.isError ? "✗" : "✓", attributes: [
                .font: font, .foregroundColor: result.isError ? Palette.danger : Palette.success,
            ])
        }
        if call.id == c.openToolId {
            return c.status == .waiting
                ? NSAttributedString(string: "Needs approval", attributes: [.font: font, .foregroundColor: Palette.waiting])
                : NSAttributedString(string: "running…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        return NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    // MARK: Helpers

    /// Inline markdown (bold, italic, `code`, links) into attributed text.
    static func inline(_ s: String, font: NSFont, color: NSColor,
                       parse: (String) throws -> AttributedString = parseInline) -> NSMutableAttributedString {
        // If the markdown can't be parsed, show the raw text.
        styled((try? parse(s)) ?? AttributedString(s), font: font, color: color)
    }

    /// Parsed markdown text into attributed text. Single line breaks stay line breaks, as Claude
    /// meant them (markdown would join the lines).
    static func styled(_ parsed: AttributedString, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent, !intent.isDisjoint(with: [.softBreak, .lineBreak]) {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color]))
                continue
            }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    // No background tint: on wrapped lines NSTextView smears it across the line.
                    f = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                }
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attrs[.link] = link
                // Hovering shows where a link really goes, whatever its text says.
                attrs[.toolTip] = link.absoluteString
                attrs[.foregroundColor] = Palette.accent
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }

    /// The row at the top that loads earlier history when clicked.
    static let earlierLink = URL(string: "deck://earlier")!

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Makes plain web addresses clickable wherever they appear (messages, tool output, code),
    /// leaving text that's already a link alone. Only http, https and mailto: what a click may open.
    /// Paths to PDFs, images and web pages that exist become links that open them in Deck.
    static func linkify(_ s: NSMutableAttributedString, cwd: String = "",
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        func link(_ range: NSRange, _ url: URL, tip: String) {
            var linked = false
            s.enumerateAttribute(.link, in: range) { value, _, stop in
                if value != nil { linked = true; stop.pointee = true }
            }
            if !linked { s.addAttributes([.link: url, .toolTip: tip, .foregroundColor: Palette.accent], range: range) }
        }
        let full = NSRange(location: 0, length: s.length)
        for match in detector.matches(in: s.string, range: full) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  TranscriptTextController.openableSchemes.contains(scheme) else { continue }
            link(match.range, url, tip: url.absoluteString)
        }
        for (range, file) in FileLinks.find(in: s.string, cwd: cwd, exists: exists) {
            link(range, FileLinks.link(to: file.path), tip: "Open \(file.lastPathComponent) in Deck")
        }
    }

    static func parseInline(_ s: String) throws -> AttributedString {
        try AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    static func rounded(_ image: NSImage, fitting box: NSSize) -> NSImage {
        let scale = min(box.width / max(image.size.width, 1), box.height / max(image.size.height, 1), 1)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Palette.Radius.medium, yRadius: Palette.Radius.medium).addClip()
            image.draw(in: rect)
            return true
        }
    }

    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

