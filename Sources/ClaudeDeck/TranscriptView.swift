import AppKit
import SwiftUI

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
        return name.split(separator: "__").last.map(String.init) ?? name
    }
}

/// The conversation, rendered into one native text view so you can select and copy across
/// every message (⌘A, drag, ⌘C, right-click → Copy). SwiftUI can only select within a single
/// view, so a SwiftUI list of messages can't do that.
struct TranscriptView: View {
    let model: TranscriptModel
    let cwd: String
    let status: SessionStatus
    let statusSince: Date?

    /// The last tool call, if it has no result yet. Older unresolved calls were interrupted.
    private var openTool: ToolCall? {
        guard case .tools(let calls)? = model.blocks.last, let last = calls.last,
              model.results[last.id] == nil else { return nil }
        return last
    }

    var body: some View {
        TranscriptTextView(content: TranscriptContent(
            blocks: model.blocks, results: model.results, queued: model.queued, outgoing: model.outgoing,
            cwd: cwd, status: status,
            openToolId: status == .busy || status == .waiting ? openTool?.id : nil,
            loaded: model.loaded))
            .overlay(alignment: .bottomLeading) {
                if status == .busy {
                    WorkingRow(tool: openTool, since: statusSince)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .padding(.leading, 20).padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
    }
}

struct TranscriptContent {
    let blocks: [TranscriptBlock]
    let results: [String: ToolResult]
    let queued: [String]
    let outgoing: [TranscriptModel.Outgoing]
    let cwd: String
    let status: SessionStatus
    let openToolId: String?
    let loaded: Bool

    /// Cheap fingerprint so the text is only rebuilt when something visible changed.
    var signature: String {
        "\(blocks.count)|\(blocks.last?.id ?? "")|\(lastToolCount)|\(results.count)|\(queued.joined(separator: "\u{1}"))|"
            + "\(outgoing.map { "\($0.id)\($0.delivered)" }.joined())|\(status)|\(openToolId ?? "")|\(loaded)"
    }

    private var lastToolCount: Int {
        if case .tools(let calls)? = blocks.last { return calls.count }
        return 0
    }
}

// MARK: - AppKit text view

struct TranscriptTextView: NSViewRepresentable {
    let content: TranscriptContent

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
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
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tv

        context.coordinator.textView = tv
        tv.onColumnChange = { [weak coordinator = context.coordinator] in coordinator?.render(force: true) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.content = content
        context.coordinator.render(force: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: ColumnTextView?
        var content: TranscriptContent?
        private var expanded: Set<String> = []
        private var lastSignature = ""
        private var rendered = false

        func render(force: Bool) {
            guard let tv = textView, let content, tv.columnWidth > 100 else { return }
            let signature = content.signature + "|\(expanded.sorted().joined())|\(Int(tv.columnWidth))"
            if !force && signature == lastSignature { return }
            lastSignature = signature

            let scroll = tv.enclosingScrollView
            let atBottom = !rendered || isAtBottom(scroll)
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let selection = tv.selectedRange()

            let text = TranscriptRenderer(width: tv.columnWidth, cwd: content.cwd, expanded: expanded).render(content)
            tv.textStorage?.setAttributedString(text)
            if selection.length > 0, NSMaxRange(selection) <= text.length { tv.setSelectedRange(selection) }

            if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
            if atBottom {
                tv.scrollToEndOfDocument(nil)
            } else if let scroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            rendered = true
        }

        private func isAtBottom(_ scroll: NSScrollView?) -> Bool {
            guard let scroll, let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            return visible.maxY >= doc.bounds.height - 40
        }

        /// Tool rows are links (deck://tool/<id>); clicking one expands or collapses it.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if url.scheme == "deck", url.host == "tool" {
                let id = url.lastPathComponent
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                render(force: true)
                return true
            }
            NSWorkspace.shared.open(url)
            return true
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
    var radius: CGFloat = Theme.Radius.medium
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

    private let body = NSFont.systemFont(ofSize: 13.5)
    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let accent = NSColor(Theme.accent)
    /// Claude's text and cards are indented past the ✦ marker.
    private let indent: CGFloat = 28

    func render(_ c: TranscriptContent) -> NSAttributedString {
        let out = NSMutableAttributedString()
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
                case let .taskEvent(text, ok):
                    out.append(notice(text, symbol: ok ? "✓" : "✗", color: ok ? NSColor(Theme.success) : NSColor(Theme.danger)))
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
                content.append(NSAttributedString(attachment: att))
                if i < images.count - 1 { content.append(NSAttributedString(string: " ")) }
            }
            if !text.isEmpty { content.append(NSAttributedString(string: "\n")) }
        }
        content.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: NSColor.labelColor]))

        let measured = content.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        let contentWidth = min(maxWidth, ceil(measured) + 4)

        let block = RoundedTextBlock()
        block.radius = Theme.Radius.large
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

    /// Claude's reply: ✦ marker, then markdown blocks indented past it.
    private func assistant(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var first = true
        for block in Markdown.parse(text) {
            let spacingBefore: CGFloat = first ? 16 : 4
            switch block {
            case .paragraph(let p):
                let style = paragraph { s in
                    s.headIndent = indent
                    s.firstLineHeadIndent = first ? 0 : indent
                    s.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    s.paragraphSpacingBefore = spacingBefore
                }
                if first {
                    out.append(NSAttributedString(string: "✦\t", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: accent, .paragraphStyle: style,
                    ]))
                }
                let inline = Self.inline(p, font: body, color: .labelColor)
                inline.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: inline.length))
                out.append(inline)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            case let .heading(t, level):
                let font = NSFont.systemFont(ofSize: level == 1 ? 17 : 14.5, weight: .semibold)
                let style = paragraph { s in
                    s.headIndent = indent
                    s.firstLineHeadIndent = first ? 0 : indent
                    s.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    s.paragraphSpacingBefore = first ? 16 : 10
                }
                if first {
                    out.append(NSAttributedString(string: "✦\t", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: accent, .paragraphStyle: style,
                    ]))
                }
                let inline = Self.inline(t, font: font, color: .labelColor)
                inline.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: inline.length))
                out.append(inline)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            case .code(let code):
                if first { out.append(marker()) }
                out.append(codeBlock(code, spacingBefore: first ? 0 : 6))
            case .table(let rows):
                if first { out.append(marker()) }
                out.append(table(rows))
            }
            first = false
        }
        return out
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
        block.radius = Theme.Radius.medium
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = paragraph { $0.textBlocks = [block]; $0.paragraphSpacing = 0; $0.lineSpacing = 1.5 }
        return NSAttributedString(string: code + "\n", attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
    }

    private func table(_ rows: [[String]]) -> NSAttributedString {
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
                let cellText = Self.inline(c < row.count ? row[c] : "", font: font, color: .labelColor)
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
        card.radius = Theme.Radius.medium
        card.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        card.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        card.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
        card.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
        card.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
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
            line.append(NSAttributedString(string: String(firstLine.prefix(120)), attributes: [
                .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            line.append(NSAttributedString(string: "\t"))
            line.append(status(call, result, c))
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: rowStyle, range: NSRange(location: 0, length: line.length))
            line.addAttribute(.link, value: url, range: NSRange(location: 0, length: line.length - 1))
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
                if let result {
                    var text = result.text.isEmpty ? "(no output)" : result.text
                    if text.count > 6000 { text = String(text.prefix(6000)) + "\n… (truncated)" }
                    out.append(NSAttributedString(string: text + "\n", attributes: [
                        .font: small,
                        .foregroundColor: result.isError ? NSColor(Theme.danger) : NSColor.secondaryLabelColor,
                        .paragraphStyle: detailStyle,
                    ]))
                }
            }
        }
        return out
    }

    private func status(_ call: ToolCall, _ result: ToolResult?, _ c: TranscriptContent) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        if let result {
            return NSAttributedString(string: result.isError ? "✗" : "✓", attributes: [
                .font: font, .foregroundColor: result.isError ? NSColor(Theme.danger) : NSColor(Theme.success),
            ])
        }
        if call.id == c.openToolId {
            return c.status == .waiting
                ? NSAttributedString(string: "Needs approval", attributes: [.font: font, .foregroundColor: NSColor(Theme.waiting)])
                : NSAttributedString(string: "running…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        return NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    // MARK: Helpers

    /// Inline markdown (bold, italic, `code`, links) into attributed text.
    static func inline(_ s: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    f = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                    attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06)
                }
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor(Theme.accent)
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }

    static func rounded(_ image: NSImage, fitting box: NSSize) -> NSImage {
        let scale = min(box.width / max(image.size.width, 1), box.height / max(image.size.height, 1), 1)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.medium, yRadius: Theme.Radius.medium).addClip()
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

/// Shown while Claude is busy. The transcript only gets complete messages, so this
/// fills the gap while Claude thinks or writes.
struct WorkingRow: View {
    let tool: ToolCall?
    let since: Date?
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .scaleEffect(pulse ? 1.15 : 0.8)
                .opacity(pulse ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(since, ctx.date))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { pulse = true }
    }

    private var label: String {
        guard let tool else { return "Thinking…" }
        return "Running \(ToolStyle.displayName(tool.name))…"
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
