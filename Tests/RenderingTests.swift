import AppKit

private func content(_ blocks: [TranscriptBlock], results: [String: ToolResult] = [:], queued: [String] = [],
                     outgoing: [OutgoingMessage] = [], status: SessionStatus = .idle, openToolId: String? = nil,
                     loaded: Bool = true) -> TranscriptContent {
    TranscriptContent(blocks: blocks, results: results, queued: queued, outgoing: outgoing, cwd: "/p/app",
                      status: status, openToolId: openToolId, loaded: loaded)
}

/// Lays the text out in a real text view and draws it, so block backgrounds are exercised.
@discardableResult
private func draw(_ text: NSAttributedString, width: CGFloat = 900) -> NSImage {
    let tv = ColumnTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    tv.isVerticallyResizable = true
    tv.textStorage!.setAttributedString(text)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    tv.sizeToFit()
    let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
    tv.cacheDisplay(in: tv.bounds, to: rep)
    let img = NSImage(size: tv.bounds.size); img.addRepresentation(rep)
    return img
}

func toolStyleTests() {
    test("symbols and display names") {
        let names = ["Bash", "Read", "Edit", "MultiEdit", "NotebookEdit", "Write", "Grep", "Glob", "ToolSearch", "WebFetch",
                     "WebSearch", "Agent", "Task", "Skill", "TodoWrite", "mcp__x__y", "Other"]
        for n in names { expect(NSImage(systemSymbolName: ToolStyle.symbol(n), accessibilityDescription: nil) != nil, n) }
        expectEqual(ToolStyle.displayName("mcp__srv__do_it"), "do_it")
        expectEqual(ToolStyle.displayName("Bash"), "Bash")
    }
    test("content signature changes with what's visible") {
        let a = content([])
        expect(a.signature.hasPrefix("0||false||0|"))
        let call = ToolCall(id: "t", name: "Bash", summary: "ls")
        let b = content([.tools([call, call])], openToolId: "t")
        expect(b.signature.contains("|2|") && b.signature.hasSuffix("t|true|"))
        expect(content([.item(item(.assistant("x"), "i"))]).signature != a.signature)
    }
}

func rendererTests() {
    let r = TranscriptRenderer(width: 700, cwd: "/p/app", expanded: ["t1", "t2", "t3", "t7"])
    let calls = [ToolCall(id: "t1", name: "Bash", summary: "ls /p/app/src\nmore"), ToolCall(id: "t2", name: "Read", summary: "/p/app/x"),
                 ToolCall(id: "t3", name: "Write", summary: NSHomeDirectory() + "/y"), ToolCall(id: "t4", name: "Edit", summary: "e"),
                 ToolCall(id: "t5", name: "Grep", summary: "g"),
                 ToolCall(id: "t6", name: "Glob", summary: ""),
                 ToolCall(id: "t8", name: "Bash", summary: "git log --oneline", purpose: "Show recent commits"),
                 ToolCall(id: "t7", name: "Edit", summary: "/p/app/f.swift",
                          diff: [DiffLine(kind: .context, text: "a"), DiffLine(kind: .removed, text: "b"),
                                 DiffLine(kind: .added, text: "B"), DiffLine(kind: .gap, text: "⋯ 3 unchanged lines")])]
    let results: [String: ToolResult] = ["t1": ToolResult(text: String(repeating: "o", count: 7000), isError: false),
                                         "t2": ToolResult(text: "", isError: true)]
    let md = """
    First line
    - a list right under it
    # Heading
    Some **bold**, *it*, `code`, ~~gone~~ and a [link](https://example.com).
    ## Sub
    ```
    code block
    ```
    | A | B |
    |---|---|
    | 1 |
    """

    test("renders every kind of item") {
        let c = content([
            .item(item(.user("hello", images: []))),
            .item(item(.user("", images: [image(width: 40, height: 20)]))),
            .item(item(.user("two pics", images: [image(), image()]))),
            .item(item(.command("rename x"))), .item(item(.command("/clear"))),
            .item(item(.assistant(md))),
            .item(item(.assistant("```\nstarts with code\n```"))),
            .item(item(.assistant("| only | table |"))),
            .item(item(.assistant("# Starts with heading\ntext"))),
            .item(item(.assistant("> Starts with a quote\n>\n> second part\n> > nested quote\n\nthen text\n> quoted later"))),
            .item(item(.assistant("---\nafter a rule\n\n- a list item\n  on two lines\n- [x] ticked"))),
            .item(item(.assistant("| real | table |\n|---|---|\n| **x** y | z |"))),
            .item(item(.notice("Interrupted"))), .item(item(.commandOutput("Context: 45% used"))),
            .item(item(.recap("We shipped the fix."))), .item(item(.peer(from: "warmdogo", text: "Handover\nsecond line"))),
            .item(item(.taskEvent("Built", ok: true))), .item(item(.taskEvent("Broke", ok: false))),
            .item(item(.tool(calls[0]))),
            .tools(calls),
        ], results: results, queued: ["queued msg"],
           outgoing: [OutgoingMessage(text: "sending", images: [image()]), { var o = OutgoingMessage(text: "sent", images: []); o.delivered = true; return o }()],
           status: .busy, openToolId: "t4")
        let text = r.render(c)
        let s = text.string
        for piece in ["hello", "/rename x", "/clear", "✦", "Heading", "bold", "link", "code block", "only", "Interrupted",
                      "✓ Built", "✗ Broke", "Bash", "ls src ⏎…", "~/y", "running…", "–", "(no output)", "… (truncated)",
                      "queued msg", "Queued until", "Show recent commits", "Sending…", "Sent", "starts with code", "Starts with heading", "Starts with a quote", "second part", "quoted later", "nested quote", "after a rule", "on two lines", "☑", "real", "x y", "Context: 45% used", "Recap", "We shipped the fix.", "Message from another Claude session", "warmdogo", "Handover\nsecond line", "+1", "−1", "− b", "+ B", "⋯ 3 unchanged lines"] {
            expect(s.contains(piece), "missing \(piece)")
        }
        for marker in ["> Starts", "> second", "\n>\n"] {
            expect(!s.contains(marker), "quote marker left in: \(marker)")
        }
        // Tool rows are links that toggle expansion.
        var links = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if (v as? URL)?.scheme == "deck" { links += 1 }
        }
        expect(links > 0)
        let purpose = (s as NSString).range(of: "Show recent commits")
        expectEqual(text.attribute(.toolTip, at: purpose.location, effectiveRange: nil) as? String, "git log --oneline")
        expect(s.contains("Show recent commits\t") && s.contains("\ngit log --oneline\n"), "the command on the line under its description")
        expect(!s.contains("Bash  Show recent commits"), "no tool name before a description")
        draw(text)
    }
    test("replies lay out at full width (nothing wraps letter by letter)") {
        let long = "Enterprise sales cycles are supposed to be slow, and this sentence is long enough to need the room."
        let reply = "> \(long)\n> > \(long)\n\n- \(long)\n  - [ ] \(long)\n\n---\n\n| A | B |\n|---|---|\n| \(long) | x |"
        let height = draw(r.render(content([.item(item(.assistant(reply)))]))).size.height
        expect(height < 700, "laid out \(height)pt tall")
    }
    test("images in replies: local ones are thumbnails that open full size") {
        let box = Sandbox(); defer { box.cleanup() }
        try pngData().write(to: box.root.appendingPathComponent("shot one.png"))
        box.write("notes.png", "not an image")
        let rr = TranscriptRenderer(width: 700, cwd: box.root.path, expanded: [])
        func render(_ md: String) -> NSAttributedString { rr.render(content([.item(item(.assistant(md)))])) }
        func links(_ text: NSAttributedString) -> [URL] {
            var out: [URL] = []
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { v, _, _ in if let u = v as? URL { out.append(u) } }
            return out
        }
        let local = render("Here:\n\n![the shot](shot%20one.png)")
        expect(local.containsAttachments(in: NSRange(location: 0, length: local.length)), "a thumbnail")
        expect(!local.string.contains("the shot"))
        expect(links(local).contains(FileLinks.link(to: box.root.appendingPathComponent("shot one.png").standardizedFileURL.path)))
        expect(render("![again](\(box.root.path)/shot%20one.png)").containsAttachments(in: NSRange(location: 0, length: 3)), "cached, by full path")
        expect(render("![url](file://\(box.root.path)/shot%20one.png)").containsAttachments(in: NSRange(location: 0, length: 3)), "a file: address")
        let web = render("![logo](https://example.com/logo.png)")
        expect(web.string.contains("logo") && links(web).contains(URL(string: "https://example.com/logo.png")!))
        for md in ["![gone](missing.png)", "![fake](notes.png)", "![data](data:image/png;base64,AA)"] {
            let r = render(md)
            expect(!r.containsAttachments(in: NSRange(location: 0, length: r.length)) && !links(r).contains { $0.scheme == "deck" }, md)
        }
    }
    test("waiting status marks the open tool") {
        let s = r.render(content([.tools([calls[3]])], status: .waiting, openToolId: "t4")).string
        expect(s.contains("Needs approval"))
    }
    test("empty transcript") {
        expect(r.render(content([], loaded: true)).string.contains("No messages yet"))
        expectEqual(r.render(content([], loaded: false)).length, 0)
        expectEqual(r.render(content([.item(item(.tool(calls[0])))], loaded: false)).length, 0)
    }
    test("tables, inline markdown and image helpers") {
        expectEqual(r.table([]).length, 0)
        expect(r.table([[AttributedString("a"), AttributedString("b")], [AttributedString("c")]]).string.contains("c"))
        struct Bad: Error {}
        let raw = TranscriptRenderer.inline("**x**", font: .systemFont(ofSize: 12), color: .labelColor, parse: { _ in throw Bad() })
        expectEqual(raw.string, "**x**")
        let styled = TranscriptRenderer.inline("**b** *i* `c` ~~s~~ [t](https://real.example)", font: .systemFont(ofSize: 12), color: .labelColor)
        expectEqual(styled.string, "b i c s t")
        expectEqual(styled.attribute(.toolTip, at: styled.length - 1, effectiveRange: nil) as? String, "https://real.example")
        let plain = NSMutableAttributedString(string: "See https://github.com/x/y/pull/3. Mail a@b.co, skip file:///etc/hosts and ")
        plain.append(NSAttributedString(string: "https://kept.example", attributes: [.link: URL(string: "deck://tool/1")!]))
        TranscriptRenderer.linkify(plain)
        let pr = (plain.string as NSString).range(of: "https://github.com/x/y/pull/3")
        var found = NSRange()
        expectEqual(plain.attribute(.link, at: pr.location, effectiveRange: &found) as? URL, URL(string: "https://github.com/x/y/pull/3"))
        expectEqual(found, pr) // the full stop after it isn't part of the link
        expectEqual(plain.attribute(.toolTip, at: pr.location, effectiveRange: nil) as? String, "https://github.com/x/y/pull/3")
        expectEqual((plain.attribute(.link, at: (plain.string as NSString).range(of: "a@b.co").location, effectiveRange: nil) as? URL)?.scheme, "mailto")
        expect(plain.attribute(.link, at: (plain.string as NSString).range(of: "file://").location, effectiveRange: nil) == nil)
        expectEqual(plain.attribute(.link, at: plain.length - 1, effectiveRange: nil) as? URL, URL(string: "deck://tool/1")) // already a link
        let message = r.render(content([.item(item(.assistant("Opened https://github.com/x/y/pull/4")))]))
        expect(message.attribute(.link, at: message.length - 3, effectiveRange: nil) != nil, "links in rendered messages")
        let small = TranscriptRenderer.rounded(image(width: 10, height: 10), fitting: NSSize(width: 100, height: 100))
        expectEqual(small.size, NSSize(width: 10, height: 10))
        let big = TranscriptRenderer.rounded(image(width: 400, height: 200), fitting: NSSize(width: 100, height: 100))
        expectEqual(big.size, NSSize(width: 100, height: 50))
        expect(big.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        let tinted = TranscriptRenderer.tinted(image(), .red)
        expect(tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
}

func textViewTests() {
    test("column view centers a fixed column and reports changes") {
        let tv = ColumnTextView(frame: .zero)
        var changes = 0
        tv.onColumnChange = { changes += 1 }
        tv.setFrameSize(NSSize(width: 1200, height: 100))
        expectEqual(tv.textContainerInset.width, 220)
        tv.setFrameSize(NSSize(width: 1200, height: 300)) // same width: no change
        tv.setFrameSize(NSSize(width: 400, height: 100))
        expectEqual(tv.textContainerInset.width, 28)
        expect(waitUntil { changes == 2 })
        tv.textContainer = nil
        tv.setFrameSize(NSSize(width: 500, height: 100))
        expectEqual(tv.columnWidth, 500 - 28 * 2)
    }
    test("pinned scroll view keeps the document as wide as the visible area") {
        let scroll = PinnedScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.tile() // no document yet
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        scroll.documentView = doc
        scroll.tile()
        expectEqual(doc.frame.width, scroll.contentView.bounds.width)
        scroll.tile()
    }
    test("controller: renders, follows the bottom, respects scrolling up, expands tools, opens safe links") {
        var opened: [URL] = []
        let ctl = TranscriptTextController(openURL: { opened.append($0); return true })
        let scroll = ctl.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        scroll.tile()
        let tv = ctl.textView!
        ctl.render(force: false) // no content yet
        let calls = (0..<40).map { ToolCall(id: "t\($0)", name: "Bash", summary: "cmd \($0)") }
        ctl.content = content([.tools(calls)])
        ctl.render(force: false)
        ctl.render(force: false) // unchanged: skipped
        expect(tv.string.contains("cmd 39"))
        let clip = scroll.contentView
        expect(clip.bounds.maxY >= tv.frame.height - 1, "starts at the bottom")
        // Select text, scroll to the top as a user would, and re-render: selection and position stay.
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        ctl.content = content([.tools(calls + [ToolCall(id: "new", name: "Read", summary: "f")])])
        ctl.render(force: false)
        expectEqual(clip.bounds.origin.y, 0)
        expectEqual(tv.selectedRange(), NSRange(location: 0, length: 3))
        // Sending a message jumps back to the bottom.
        ctl.content = content([.tools(calls)], outgoing: [OutgoingMessage(text: "hi", images: [])])
        ctl.render(force: false)
        expect(clip.bounds.maxY >= tv.frame.height - 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25)) // delayed re-pins
        // Clicking a tool row expands it, again collapses.
        expect(ctl.textView(tv, clickedOnLink: URL(string: "deck://tool/t0")!, at: 0))
        expect(tv.string.contains("cmd 0\ncmd 0") || tv.string.components(separatedBy: "cmd 0").count > 2)
        expect(ctl.textView(tv, clickedOnLink: URL(string: "deck://tool/t0")!, at: 0))
        // External links: only web and mail.
        for link in ["https://example.com", "mailto:a@b.c", "file:///etc/passwd", "vscode://x", "deck://other"] {
            expect(ctl.textView(tv, clickedOnLink: URL(string: link)!, at: 0))
        }
        expectEqual(opened.map(\.absoluteString), ["https://example.com", "mailto:a@b.c"])
        expect(!ctl.textView(tv, clickedOnLink: "not a url", at: 0))
        tv.onColumnChange?()
    }
    test("controller without a scroll view") {
        let ctl = TranscriptTextController(openURL: { _ in false })
        let tv = ColumnTextView(frame: .zero)
        tv.setFrameSize(NSSize(width: 900, height: 300))
        ctl.textView = tv
        ctl.content = content([.item(item(.assistant("hi")))])
        ctl.render(force: true)
        ctl.userScrolled()
        expect(tv.string.contains("hi"))
        let narrow = TranscriptTextController(openURL: { _ in false })
        let small = ColumnTextView(frame: .zero)
        small.setFrameSize(NSSize(width: 120, height: 100))
        narrow.textView = small
        narrow.content = content([.item(item(.assistant("hi")))])
        narrow.render(force: true)
        expect(small.string.isEmpty, "too narrow to lay out yet")
        _ = small
    }
    test("a quote copies with one click") {
        let ctl = TranscriptTextController(openURL: { _ in false })
        let tv = ColumnTextView(frame: .zero)
        tv.setFrameSize(NSSize(width: 900, height: 300))
        ctl.textView = tv
        let pb = NSPasteboard(name: .init("deck-test-quote"))
        ctl.pasteboard = pb
        ctl.content = content([.item(item(.assistant("""
            Before.

            > The **first** line
            > - one
            > > nested
            > ```
            > code
            > ```
            > ---

            Between.

            > Last quote
            """)))])
        ctl.render(force: true)
        let storage = tv.textStorage!
        var links: [(Int, String)] = []
        storage.enumerateAttribute(TranscriptRenderer.copyText, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let v = v as? String { links.append((r.location, v)) }
        }
        expectEqual(links.map(\.1), ["The first line\n\n• one\n\nnested\n\ncode\n\n---", "Last quote"])
        let cell = { (s: String) in AttributedString(s) }
        expectEqual(TranscriptRenderer.plain(Markdown.Block(kind: .table([[cell("a"), cell("b")], [cell("1"), cell("2")]]))), "a\tb\n1\t2")
        expect(storage.string.components(separatedBy: TranscriptRenderer.copyLabel).count == 3, "one link per quote")
        expect(ctl.textView(tv, clickedOnLink: TranscriptRenderer.copyLink, at: links[1].0))
        expectEqual(pb.string(forType: .string), "Last quote")
        expect(storage.string.contains("✓ Copied"))
        ctl.copyBlock(in: tv, at: 0)
        ctl.copyBlock(in: tv, at: storage.length + 5)
        expectEqual(pb.string(forType: .string), "Last quote") // no quote there
        pb.releaseGlobally()
    }
    test("a code block copies with one click") {
        let ctl = TranscriptTextController(openURL: { _ in false })
        let tv = ColumnTextView(frame: .zero)
        tv.setFrameSize(NSSize(width: 900, height: 300))
        ctl.textView = tv
        let pb = NSPasteboard(name: .init("deck-test-code"))
        ctl.pasteboard = pb
        ctl.content = content([.item(item(.assistant("Paste this:\n\n```\nline one\n  line two\n```\n\nDone.")))])
        ctl.render(force: true)
        let storage = tv.textStorage!
        let at = (storage.string as NSString).range(of: TranscriptRenderer.copyCodeLabel).location
        expect(at != NSNotFound, "the link is there")
        expect(ctl.textView(tv, clickedOnLink: TranscriptRenderer.copyLink, at: at))
        expectEqual(pb.string(forType: .string), "line one\n  line two")
        expect(storage.string.contains("✓ Copied"))
        pb.releaseGlobally()
    }
    test("select to copy: a mouse selection goes to the clipboard") {
        let tv = ColumnTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.string = "Backend goes first   "
        let pb = NSPasteboard(name: .init("deck-test-select"))
        pb.clearContents()
        tv.copyIfSelected(to: pb)
        expect(pb.string(forType: .string) == nil, "nothing selected, nothing copied")
        tv.setSelectedRange(NSRange(location: 18, length: 3))
        tv.copyIfSelected(to: pb)
        expect(pb.string(forType: .string) == nil, "only spaces selected")
        tv.setSelectedRange(NSRange(location: 0, length: 7))
        tv.copyIfSelected(to: pb)
        expectEqual(pb.string(forType: .string), "Backend")
        // A click: the text view tracks the mouse until it's released (posted first, so it returns).
        _ = NSApplication.shared
        let win = NSWindow(contentRect: tv.frame, styleMask: [], backing: .buffered, defer: true)
        win.contentView = tv
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        tv.mouseDown(with: mouse(.leftMouseDown))
        pb.releaseGlobally()
    }
}
