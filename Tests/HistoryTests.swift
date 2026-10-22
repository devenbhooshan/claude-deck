import AppKit

/// One message per line; `pad` makes lines long, like real transcripts.
private func message(_ i: Int, pad: Int = 0, twoTexts: Bool = false) -> [String: Any] {
    if twoTexts {
        return ["type": "assistant", "uuid": "u\(i)", "message": ["content": [["type": "text", "text": "a\(i)"], ["type": "text", "text": "b\(i)"]]]]
    }
    return ["type": i % 2 == 0 ? "user" : "assistant", "uuid": "u\(i)",
            "message": ["content": (i % 2 == 0 ? "question \(i) " : "answer \(i) ") + String(repeating: "x", count: pad)]]
}

private func firstUUID(_ p: TranscriptParser) -> String { String(p.items.first!.id.split(separator: "-")[0]) }

func historyTests() {
    test("lines before a point, reading further back for long lines") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.write("t.jsonl", "first\n" + String(repeating: "y", count: 500) + "\nthird\nfourth\n")
        let (all, _) = TailReader.readLines(url, from: nil, maxBytes: 10_000)
        expectEqual(all.map(\.offset), [0, 6, 507, 513])
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in all {
            let start = text.utf8.index(text.utf8.startIndex, offsetBy: Int(line.offset))
            expect(text.utf8[start...].starts(with: line.data))
        }
        // 10 bytes back from "fourth" finds "third"; from "third" it keeps doubling past the long line.
        expectEqual(TailReader.lines(before: 513, in: url, chunk: 10).map(\.offset), [507])
        expectEqual(TailReader.lines(before: 507, in: url, chunk: 10).map(\.offset), [0, 6])
        expectEqual(TailReader.lines(before: 6, in: url, chunk: 10).map(\.offset), [0])
        expectEqual(TailReader.lines(before: 513, in: url, chunk: 10_000).count, 3)
        expect(TailReader.lines(before: 5, in: box.root.appendingPathComponent("missing"), chunk: 10).isEmpty)
        expectEqual(TailReader.lines(before: 10_000, in: url, chunk: 10).count, 4) // past the end: the whole file
    }
    test("a long session: the latest part first, earlier history on demand") {
        let box = Sandbox(); defer { box.cleanup() }
        var records: [[String: Any]] = [
            ["type": "ai-title", "aiTitle": "Old title"],
            ["type": "queue-operation", "operation": "enqueue", "content": "old queued"],
        ]
        records += (0..<2000).map { message($0, pad: 3000) } // ~6MB: more than the first read
        records.append(["type": "ai-title", "aiTitle": "New title"])
        let url = box.jsonl("t.jsonl", records)
        let p = TranscriptParser(url: url)
        p.refresh()
        expectEqual(p.items.count, TranscriptParser.maxItems)
        expect(p.hasEarlier)
        expectEqual(firstUUID(p), "u1400")
        expect(p.loadEarlier(minItems: 150, chunk: 100_000))
        expect(p.items.count >= 750)
        let ids = p.items.map { Int($0.id.split(separator: "-")[0].dropFirst())! }
        expect(ids == Array(ids.first!...1999), "no gaps or repeats")
        // Following new messages doesn't drop the history you loaded.
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile()
        h.write(try JSONSerialization.data(withJSONObject: message(2000))); h.write(Data("\n".utf8)); try h.close()
        p.refresh()
        expectEqual(p.items.count, ids.count + 1)
        // All the way back: the old title and queue are history, not the current state.
        p.loadEarlier(minItems: 100_000, chunk: 1_000_000)
        expectEqual(p.items.count, 2001)
        expect(!p.hasEarlier)
        expect(!p.loadEarlier())
        expectEqual(p.title, "New title")
        expectEqual(p.queued, [])
    }
    test("huge lines: the first load reads further back for enough messages") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.jsonl("t.jsonl", (0..<420).map { message($0, pad: $0 < 400 ? 6_000 : 300_000) })
        let p = TranscriptParser(url: url)
        p.refresh()
        expect(p.items.count >= TranscriptParser.minFirstLoad)
        expect(p.hasEarlier)
        expectEqual(p.items.last.map { String($0.id.split(separator: "-")[0]) }, "u419")
    }
    test("trimming cuts at a line boundary") {
        let box = Sandbox(); defer { box.cleanup() }
        let url = box.jsonl("t.jsonl", (0..<1000).map { message($0, twoTexts: true) } + [message(1000)])
        let p = TranscriptParser(url: url)
        p.refresh()
        expectEqual(p.items.count, TranscriptParser.maxItems - 1) // not half of line 700
        expectEqual(firstUUID(p), "u701")
        p.loadEarlier(minItems: 1, chunk: 60)
        expectEqual(p.items.count, TranscriptParser.maxItems + 1) // line 700, both halves
        expectEqual(firstUUID(p), "u700")
    }
    test("nothing but blank lines before") {
        let box = Sandbox(); defer { box.cleanup() }
        let body = (0..<700).map { String(decoding: try! JSONSerialization.data(withJSONObject: message($0)), as: UTF8.self) }
        let url = box.write("t.jsonl", "\n\n\n" + body.joined(separator: "\n") + "\n")
        let p = TranscriptParser(url: url)
        p.refresh()
        p.loadEarlier(minItems: 1_000)
        expectEqual(p.items.count, 700)
        expect(!p.hasEarlier)
        let empty = TranscriptParser(url: box.write("e.jsonl", ""))
        empty.refresh()
        expect(!empty.hasEarlier)
    }
    test("transcript view: the top row, loading on scroll up, keeping your place") {
        var asked = 0
        let ctl = TranscriptTextController(openURL: { _ in true })
        ctl.onReachTop = { asked += 1 }
        let scroll = ctl.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        scroll.tile()
        let tv = ctl.textView!
        func content(_ range: ClosedRange<Int>, earlier: Bool) -> TranscriptContent {
            TranscriptContent(blocks: range.map { .item(item(.assistant("message \($0)"), "m\($0)")) }, results: [:], queued: [],
                              outgoing: [], cwd: "", status: .idle, openToolId: nil, loaded: true, hasEarlier: earlier)
        }
        ctl.content = content(50...99, earlier: true)
        ctl.render(force: false)
        expect(tv.string.hasPrefix("↑ Earlier messages load as you scroll up"))
        expect(ctl.textView(tv, clickedOnLink: TranscriptRenderer.earlierLink, at: 0))
        expectEqual(asked, 1)
        // Scroll to the top: asks for more, and reading position survives the insert above.
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 100)); scroll.reflectScrolledClipView(clip)
        ctl.userScrolled()
        expectEqual(asked, 2)
        let y = clip.bounds.minY
        let probe = tv.layoutManager!.characterIndexForGlyph(at: tv.layoutManager!.glyphIndex(for: NSPoint(x: 40, y: y + 40), in: tv.textContainer!))
        let reading = (tv.string as NSString).substring(with: (tv.string as NSString).lineRange(for: NSRange(location: probe, length: 0)))
        ctl.content = content(0...99, earlier: false)
        ctl.render(force: false)
        expect(!tv.string.contains("Earlier messages"))
        let after = tv.layoutManager!.characterIndexForGlyph(at: tv.layoutManager!.glyphIndex(for: NSPoint(x: 40, y: clip.bounds.minY + 40), in: tv.textContainer!))
        expectEqual((tv.string as NSString).substring(with: (tv.string as NSString).lineRange(for: NSRange(location: after, length: 0))), reading)
        // Nothing earlier: scrolling up doesn't ask.
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        ctl.userScrolled()
        expectEqual(asked, 2)
    }
}
