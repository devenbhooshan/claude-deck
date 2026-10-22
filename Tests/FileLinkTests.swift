import AppKit

func fileLinkTests() {
    let home = NSHomeDirectory()
    test("which files Deck shows") {
        expectEqual(FileLinks.kind(of: URL(fileURLWithPath: "/a/Report.PDF")), .pdf)
        expectEqual(FileLinks.kind(of: URL(fileURLWithPath: "/a/shot.jpeg")), .image)
        expectEqual(FileLinks.kind(of: URL(fileURLWithPath: "/a/chart.svg")), .html)
        expectEqual(FileLinks.kind(of: URL(fileURLWithPath: "/a/index.htm")), .html)
        expectEqual(FileLinks.kind(of: URL(fileURLWithPath: "/a/run.sh")), nil)
    }
    test("paths found in text, resolved, only if the file exists") {
        let files: Set<String> = ["/p/docs/report.pdf", "/p/out.png", "\(home)/Desktop/Screenshot 2026-10-21 at 9.57.47 AM.png",
                                  "/tmp/page.html", "/p/a.pdf"]
        let text = """
            Wrote docs/report.pdf and `./out.png`. See ~/Desktop/Screenshot 2026-10-21 at 9.57.47 AM.png, (/tmp/page.html).
            Not: missing.pdf, report.pdf.bak, run.sh, https://x.com/out.png, a.pdfx, ../a.pdf
            """
        let found = FileLinks.find(in: text, cwd: "/p/sub", exists: files.contains)
        expectEqual(found.map(\.1.path), ["\(home)/Desktop/Screenshot 2026-10-21 at 9.57.47 AM.png", "/tmp/page.html", "/p/a.pdf"])
        let atRoot = FileLinks.find(in: text, cwd: "/p", exists: files.contains)
        expectEqual(atRoot.map { (text as NSString).substring(with: $0.0) },
                    ["docs/report.pdf", "./out.png", "~/Desktop/Screenshot 2026-10-21 at 9.57.47 AM.png", "/tmp/page.html"])
        expect(FileLinks.find(in: "docs/report.pdf", cwd: "", exists: files.contains).isEmpty, "relative with no folder")
        expect(FileLinks.find(in: "/nonexistent/x.pdf", cwd: "").isEmpty, "checks the disk by default")
    }
    test("links: the viewer's own, file://, relative markdown; nothing else") {
        let link = FileLinks.link(to: "/a b/r.pdf")
        expectEqual(link.scheme, "deck")
        expectEqual(FileLinks.file(for: link, cwd: "")?.path, "/a b/r.pdf")
        expectEqual(FileLinks.file(for: URL(string: "file:///x/y.png")!, cwd: "")?.path, "/x/y.png")
        expectEqual(FileLinks.file(for: URL(string: "docs/r%20s.html")!, cwd: "/p")?.path, "/p/docs/r s.html")
        expect(FileLinks.file(for: URL(string: "file:///x/run.sh")!, cwd: "") == nil, "not a kind Deck shows")
        expect(FileLinks.file(for: URL(string: "https://x.com/y.png")!, cwd: "") == nil, "web links go to the browser")
        expect(FileLinks.file(for: URL(string: "deck://open")!, cwd: "") == nil)
        expect(FileLinks.file(for: URL(string: "deck://tool/x.png")!, cwd: "") == nil)
    }
    test("transcript: paths become viewer links, clicks open the viewer") {
        let box = Sandbox(); defer { box.cleanup() }
        let pdf = box.write("proj/report.pdf", "%PDF")
        let s = NSMutableAttributedString(string: "Saved report.pdf to https://x.com/report.pdf")
        TranscriptRenderer.linkify(s, cwd: pdf.deletingLastPathComponent().path)
        let link = s.attribute(.link, at: 7, effectiveRange: nil) as? URL
        expectEqual(link.flatMap { FileLinks.file(for: $0, cwd: "") }?.path, pdf.standardizedFileURL.path)
        expectEqual(s.attribute(.toolTip, at: 7, effectiveRange: nil) as? String, "Open report.pdf in Deck")
        expectEqual((s.attribute(.link, at: s.length - 3, effectiveRange: nil) as? URL)?.host, "x.com")
        var opened: [URL] = []
        var browsed: [URL] = []
        let ctl = TranscriptTextController(openURL: { browsed.append($0); return true }, openFile: { opened.append($0) })
        let tv = NSTextView()
        expect(ctl.textView(tv, clickedOnLink: link!, at: 0))
        expect(ctl.textView(tv, clickedOnLink: URL(string: "file:///etc/hosts")!, at: 0))
        expectEqual(opened.map(\.path), [pdf.standardizedFileURL.path])
        expect(browsed.isEmpty, "file:// that Deck can't show is never opened")
        TranscriptTextController(openURL: { _ in true }).textView(tv, clickedOnLink: link!, at: 0) // default: no viewer
    }
    test("images you shared: saved full size, thumbnail opens it") {
        let box = Sandbox(); defer { box.cleanup() }
        let png = pngData(width: 40, height: 20)
        let block: [String: Any] = ["type": "image", "source": ["data": png.base64EncodedString(), "media_type": "image/jpeg"]]
        let url = box.jsonl("t.jsonl", [["type": "user", "message": ["content": [["type": "text", "text": "look"], block]]]])
        let p = TranscriptParser(url: url)
        p.refresh()
        guard case let .user(_, images)? = p.items.first?.kind, let thumb = images.first as? TranscriptImage,
              let file = thumb.file else { return expect(false, "parsed image with a file") }
        expectEqual(file.pathExtension, "jpeg")
        expectEqual(try? Data(contentsOf: file), png)
        // The same image again reuses the file and keeps it fresh.
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        expectEqual(AttachmentStore.saveTranscriptImage(png, mediaType: "image/jpeg"), file)
        let mtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        expect(mtime.map { Date().timeIntervalSince($0) < 60 } == true)
        expectEqual(AttachmentStore.saveTranscriptImage(Data([1]), mediaType: nil)?.pathExtension, "png")
        let saved = AttachmentStore.dir
        AttachmentStore.dir = URL(fileURLWithPath: "/dev/null/nope")
        expect(AttachmentStore.saveTranscriptImage(Data([2]), mediaType: nil) == nil, "can't save: no file, still a thumbnail")
        AttachmentStore.dir = saved

        // Rendered: the thumbnail is a link to the full image; clicking it opens the viewer.
        var opened: [URL] = []
        let ctl = TranscriptTextController(openURL: { _ in true }, openFile: { opened.append($0) })
        let scroll = ctl.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        scroll.tile()
        ctl.content = TranscriptContent(blocks: [.item(item(.user("look", images: [thumb, image()])))], results: [:], queued: [],
                                        outgoing: [], cwd: "", status: .idle, openToolId: nil, loaded: true, focus: nil)
        ctl.render(force: true)
        let tv = ctl.textView!
        let text = tv.textStorage!.string as NSString
        let at = text.range(of: "\u{FFFC}").location
        expect(tv.textStorage!.attribute(.link, at: at, effectiveRange: nil) != nil)
        expectEqual(tv.textStorage!.attribute(.toolTip, at: at, effectiveRange: nil) as? String, "Click to view full size")
        let cell = NSTextAttachmentCell()
        ctl.textView(tv, clickedOn: cell, in: .zero, at: at)
        expectEqual(opened, [file.standardizedFileURL])
        ctl.textView(tv, clickedOn: cell, in: .zero, at: text.range(of: "\u{FFFC}", options: .backwards).location) // plain image: no file
        ctl.textView(tv, clickedOn: cell, in: .zero, at: text.length + 5)
        expectEqual(opened.count, 1)
    }
}
