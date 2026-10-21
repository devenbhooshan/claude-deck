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
}
