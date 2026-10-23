import Foundation

func markdownEditorTests() {
    func spans(_ text: String) -> [(String, MarkdownSyntax.Kind)] {
        MarkdownSyntax.spans(in: text).map { ((text as NSString).substring(with: $0.range), $0.kind) }
    }
    func has(_ found: [(String, MarkdownSyntax.Kind)], _ text: String, _ kind: MarkdownSyntax.Kind) -> Bool {
        found.contains { $0.0 == text && $0.1 == kind }
    }

    test("syntax: headings, rules, quotes, tables") {
        let s = spans("# Title **b**\n###\n---\n> said `x`\n| a | b |\nplain")
        expect(has(s, "# Title **b**", .heading(1)) && has(s, "#", .mark) && has(s, "b", .bold))
        expect(has(s, "###", .heading(3)), "a heading with no text")
        expect(has(s, "---", .rule))
        expect(has(s, "> said `x`", .quote) && has(s, "> ", .mark) && has(s, "x", .code))
        expect(has(s, "| a | b |", .table))
        expect(!s.contains { $0.0 == "plain" }, "a plain line has no spans")
    }
    test("syntax: lists and tasks") {
        let s = spans("- one\n2. two\n- [ ] todo\n* [x] shipped *it*")
        expect(has(s, "-", .listMarker) && has(s, "2.", .listMarker) && has(s, "*", .listMarker))
        expect(has(s, "[ ]", .task(done: false)) && has(s, "[x]", .task(done: true)))
        expect(has(s, "shipped *it*", .done) && !has(s, "todo", .done))
        expect(has(s, "it", .italic))
    }
    test("syntax: fenced code is left alone") {
        let s = spans("```swift\nlet **a** = 1\n```\n~~~\nopen")
        expect(has(s, "```swift", .codeBlock) && has(s, "```swift", .mark) && has(s, "```", .mark))
        expect(has(s, "let **a** = 1", .codeBlock) && !s.contains { $0.1 == .bold })
        expect(has(s, "open", .codeBlock), "an unclosed fence runs to the end")
    }
    test("syntax: inline styles, not inside code spans") {
        let s = spans("**bold** _it_ ~~gone~~ [Deck](https://x.y) `**raw**` snake_case_name ***")
        expect(has(s, "bold", .bold) && has(s, "**", .mark))
        expect(has(s, "it", .italic) && has(s, "gone", .strike))
        expect(has(s, "Deck", .link) && has(s, "https://x.y", .url) && has(s, "](", .mark) && has(s, ")", .mark))
        expect(has(s, "**raw**", .code) && !has(s, "raw", .bold))
        expect(!s.contains { $0.0 == "case" }, "underscores inside words aren't italic")
        expect(!has(s, "bold", .italic), "bold isn't also italic")
    }

    test("editing: tick a task") {
        let text = "- [ ] a\n- [X] b\n- c"
        let tick = MarkdownEditing.toggleTask(at: 3, in: text)
        expectEqual(tick, .init(range: NSRange(location: 2, length: 3), text: "[x]", selection: NSRange(location: 5, length: 0)))
        expectEqual(MarkdownEditing.toggleTask(at: 11, in: text)?.text, "[ ]")
        expect(MarkdownEditing.toggleTask(at: 6, in: text) == nil, "beside the box")
        expect(MarkdownEditing.toggleTask(at: 17, in: text) == nil, "not a task")
        expect(MarkdownEditing.toggleTask(at: 99, in: text) == nil, "past the end")
        expect(MarkdownEditing.toggleTask(at: 0, in: "plain") == nil)
    }
    test("editing: wrap and unwrap") {
        let text = "say hi now"
        let bold = MarkdownEditing.wrap(NSRange(location: 4, length: 2), in: text, with: "**")
        expectEqual(bold, .init(range: NSRange(location: 4, length: 2), text: "**hi**", selection: NSRange(location: 6, length: 2)))
        let wrapped = "say **hi** now"
        expectEqual(MarkdownEditing.wrap(NSRange(location: 6, length: 2), in: wrapped, with: "**"),
                    .init(range: NSRange(location: 4, length: 6), text: "hi", selection: NSRange(location: 4, length: 2)))
        expectEqual(MarkdownEditing.wrap(NSRange(location: 4, length: 6), in: wrapped, with: "**"),
                    .init(range: NSRange(location: 4, length: 6), text: "hi", selection: NSRange(location: 4, length: 2)))
        expectEqual(MarkdownEditing.wrap(NSRange(location: 0, length: 0), in: "", with: "`").selection, NSRange(location: 1, length: 0))
        expectEqual(MarkdownEditing.wrap(NSRange(location: 0, length: 1), in: "*", with: "*").text, "***")  // too short to unwrap
    }
    test("editing: links") {
        let e = MarkdownEditing.link(NSRange(location: 0, length: 4), in: "Deck docs")
        expectEqual(e.text, "[Deck](https://)")
        expectEqual(("[Deck](https://)" as NSString).substring(with: NSRange(location: e.selection.location, length: e.selection.length)), "https://")
    }
    test("editing: return continues lists") {
        func next(_ text: String) -> String? { MarkdownEditing.newline(at: (text as NSString).length, in: text)?.text }
        expectEqual(next("- a"), "\n- ")
        expectEqual(next("x\n  9) b"), "\n  10) ")
        expectEqual(next("- [x] done"), "\n- [ ] ")
        expect(next("plain") == nil)
        expect(MarkdownEditing.newline(at: 1, in: "- a") == nil, "only at the end of the line")
        let end = MarkdownEditing.newline(at: 8, in: "- a\n  - \nz")
        expectEqual(end, .init(range: NSRange(location: 4, length: 4), text: "", selection: NSRange(location: 4, length: 0)))
        expectEqual(next("- [ ] ").map { $0.isEmpty }, true)  // an empty task ends the list too
    }
    test("editing: lines and feedback") {
        let text = "a\nb\nc\n"
        expectEqual(MarkdownEditing.lines(of: NSRange(location: 2, length: 3), in: text), 2...3)
        expectEqual(MarkdownEditing.lines(of: NSRange(location: 2, length: 2), in: text), 2...2)  // the newline ending a line
        expectEqual(MarkdownEditing.lines(of: NSRange(location: 0, length: 0), in: text), 1...1)
        expectEqual(MarkdownEditing.feedback(path: "/p/docs/plan.md", cwd: "/p", lines: 2...3, excerpt: "b\nc\n", note: " later \n"),
                    "In docs/plan.md, lines 2–3:\n> b\n> c\n\nlater")
        expectEqual(MarkdownEditing.feedback(path: "/q/a.md", cwd: "/p", lines: 4...4, excerpt: "x", note: "why"),
                    "In /q/a.md, line 4:\n> x\n\nwhy")
        expect(MarkdownEditing.feedback(path: "/a.md", cwd: "", lines: 1...1, excerpt: "x", note: "").hasPrefix("In /a.md"))
    }
    test("editing: the file changed on disk") {
        expectEqual(MarkdownEditing.diskChanged(saved: "a", current: "b", disk: "b"), .same)
        expectEqual(MarkdownEditing.diskChanged(saved: "a", current: "ab", disk: "a"), .same)
        expectEqual(MarkdownEditing.diskChanged(saved: "a", current: "a", disk: "c"), .reload)
        expectEqual(MarkdownEditing.diskChanged(saved: "a", current: "b", disk: "c"), .conflict)
    }

    test("preview: blocks") {
        let html = MarkdownHTML.render("""
            # Plan *now*
            ##

            Intro line
            continues.

            ---
            > quoted **bold**
            > more
            | Name | Age |
            |------|----:|
            | <b>  | 3   |
            | solo |
            ```js
            let a = 1 < 2
            ```
            ~~~
            raw
            ~~~
            """)
        expect(html.contains("<h1>Plan <em>now</em></h1>") && html.contains("<h2></h2>"))
        expect(html.contains("<p>Intro line continues.</p>"))
        expect(html.contains("<hr>"))
        expect(html.contains("<blockquote><p>quoted <strong>bold</strong> more</p></blockquote>"))
        expect(html.contains("<tr><th>Name</th><th>Age</th></tr><tr><td>&lt;b&gt;</td><td>3</td></tr><tr><td>solo</td></tr>"))
        expect(html.contains("<pre><code class=\"language-js\">let a = 1 &lt; 2</code></pre>"))
        expect(html.contains("<pre><code>raw</code></pre>"))
        expect(MarkdownHTML.render("| a |").contains("<tr><td>a</td></tr>"), "a table with no header")
    }
    test("preview: lists") {
        let html = MarkdownHTML.render("- a\n  wrapped\n  - b\n    1. c\n- [x] d\n- [ ] e\n\n1. x")
        expectEqual(html, """
            <ul><li>a wrapped<ul><li>b<ol><li>c</li></ol></li></ul></li>\
            <li class="task"><input type="checkbox" disabled checked> d</li>\
            <li class="task"><input type="checkbox" disabled> e</li></ul>
            <ol><li>x</li></ol>
            """)
    }
    test("preview: inline, links and images, safely") {
        let inline = MarkdownHTML.inline("`<a>` [**x** `y`](https://a.b?q=1&r=2) ~~old~~ ![pic](shot.png) see https://x.y/z. [bad](javascript:alert(1)) ![w](https://i/p.png) ![x](javascript:1)",
                                         image: { $0 == "shot.png" ? "data:image/png;base64,AA" : nil })
        expect(inline.contains("<code>&lt;a&gt;</code>"))
        expect(inline.contains("<a href=\"https://a.b?q=1&amp;r=2\"><strong>x</strong> <code>y</code></a>"))
        expect(inline.contains("<del>old</del>"))
        expect(inline.contains("<img src=\"data:image/png;base64,AA\" alt=\"pic\">"))
        expect(inline.contains("see <a href=\"https://x.y/z\">https://x.y/z</a>."))
        expect(inline.contains(" bad") && !inline.contains("javascript"), "unsafe links lose their address")
        expect(inline.contains("<img src=\"https://i/p.png\" alt=\"w\">") && inline.contains("<img src=\"\" alt=\"x\">"))
        expect(MarkdownHTML.safe("#top") && MarkdownHTML.safe("docs/a.md") && MarkdownHTML.safe("a/b:c") && MarkdownHTML.safe("#x:y"))
        expect(MarkdownHTML.safe("MAILTO:a@b.c") && !MarkdownHTML.safe("file:///etc/passwd"))
        expectEqual(MarkdownHTML.render("x"), "<p>x</p>")
        expectEqual(MarkdownHTML.render("![a](b.png)"), "<p><img src=\"b.png\" alt=\"a\"></p>")
        expectEqual(MarkdownHTML.inline("![a](b.png)"), "<img src=\"b.png\" alt=\"a\">")
        expectEqual(MarkdownHTML.render("- a\n\tb"), "<ul><li>a b</li></ul>")
    }
    test("preview: page") {
        let page = MarkdownHTML.page("<p>x</p>", background: "#fff", text: "#111", secondary: "#666", accent: "#d97757", fill: "#eee")
        expect(page.contains("<p>x</p>") && page.contains("background: #fff") && page.contains("#d97757"))
    }
}
