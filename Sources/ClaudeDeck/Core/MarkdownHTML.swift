import Foundation

/// The editor's preview: markdown to HTML. Everything in the file is escaped (no raw HTML
/// passes through), and links keep only web, mail, in-page and relative addresses.
enum MarkdownHTML {
    /// `image` turns an image address into something the page can load (a data: URL for a local
    /// file), or nil to leave it as written.
    static func render(_ text: String, image: (String) -> String? = { _ in nil }) -> String {
        var out: [String] = []
        var para: [String] = []
        var lines = ArraySlice(text.components(separatedBy: "\n"))

        func flush() {
            if !para.isEmpty { out.append("<p>\(inline(para.joined(separator: " "), image: image))</p>") }
            para = []
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let full = NSRange(location: 0, length: (line as NSString).length)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(next) }
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
            } else if trimmed.isEmpty {
                flush()
            } else if let m = MarkdownSyntax.heading.firstMatch(in: line, range: full) {
                flush()
                let level = m.range(at: 1).length
                let title = m.range(at: 2).location == NSNotFound ? "" : (line as NSString).substring(with: m.range(at: 2))
                out.append("<h\(level)>\(inline(title, image: image))</h\(level)>")
            } else if MarkdownSyntax.rule.firstMatch(in: line, range: full) != nil {
                flush()
                out.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted = [line]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") { quoted.append(lines.removeFirst()) }
                let inner = quoted.map { l -> String in
                    let m = MarkdownSyntax.quote.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length))!
                    return (l as NSString).substring(with: m.range(at: 2))
                }
                out.append("<blockquote>\(render(inner.joined(separator: "\n"), image: image))</blockquote>")
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [line]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(lines.removeFirst()) }
                out.append(table(rows, image: image))
            } else if MarkdownSyntax.listItem.firstMatch(in: line, range: full) != nil {
                flush()
                var items = [line]
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).isEmpty,
                      isItem(next) || next.hasPrefix(" ") || next.hasPrefix("\t") { items.append(lines.removeFirst()) }
                out.append(list(items, image: image))
            } else {
                para.append(trimmed)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static func isItem(_ line: String) -> Bool {
        MarkdownSyntax.listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Nested lists by indentation: deeper items open a list inside the item above.
    private static func list(_ lines: [String], image: (String) -> String?) -> String {
        var html = ""
        var open: [(indent: Int, tag: String)] = []
        for line in lines {
            let ns = line as NSString
            guard let m = MarkdownSyntax.listItem.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                // A wrapped line of the item above.
                html += " " + inline(line.trimmingCharacters(in: .whitespaces), image: image)
                continue
            }
            let indent = m.range(at: 1).length
            let tag = ns.substring(with: m.range(at: 2)).first!.isNumber ? "ol" : "ul"
            while let last = open.last, last.indent > indent {
                html += "</li></\(last.tag)>"
                open.removeLast()
            }
            if let last = open.last, last.indent == indent {
                html += "</li>"
            } else {
                html += "<\(tag)>"
                open.append((indent, tag))
            }
            let text = inline(ns.substring(with: m.range(at: 5)), image: image)
            if m.range(at: 4).location != NSNotFound {
                let done = ns.substring(with: m.range(at: 4)).lowercased().hasPrefix("[x")
                html += "<li class=\"task\"><input type=\"checkbox\" disabled\(done ? " checked" : "")> \(text)"
            } else {
                html += "<li>\(text)"
            }
        }
        for level in open.reversed() { html += "</li></\(level.tag)>" }
        return html
    }

    private static func table(_ rows: [String], image: (String) -> String?) -> String {
        func cells(_ row: String) -> [String] {
            var r = Substring(row.trimmingCharacters(in: .whitespaces))
            r = r.dropFirst()
            if r.hasSuffix("|") { r = r.dropLast() }
            return r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let parsed = rows.map(cells)
        let isSeparator = { (row: [String]) in row.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } } }
        let hasHead = parsed.count > 1 && isSeparator(parsed[1])
        var html = "<table>"
        for (i, row) in parsed.enumerated() where !(hasHead && i == 1) {
            let tag = hasHead && i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(inline($0, image: image))</\(tag)>" }.joined() + "</tr>"
        }
        return html + "</table>"
    }

    private static let codeSpan = MarkdownSyntax.regex(#"(`+)(.+?)\1"#)
    private static let link = MarkdownSyntax.regex(#"(!?)\[([^\]\n]*)\]\(([^)\s]*)\)"#)
    private static let bareURL = MarkdownSyntax.regex(#"https?://[^\s<>"]+[^\s<>".,;:!?)\]']"#)
    private static let emphasis: [(NSRegularExpression, String)] = [
        (MarkdownSyntax.regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), "<strong>$2</strong>"),
        (MarkdownSyntax.regex(#"(?<![*\w])([*_])(?![*_\s])(.+?)(?<![*_\s])\1(?![*\w])"#), "<em>$2</em>"),
        (MarkdownSyntax.regex(#"~~(?=\S)(.+?)(?<=\S)~~"#), "<del>$1</del>"),
    ]

    /// Escapes, then sets code spans, links and images aside (so nothing inside them is styled),
    /// styles emphasis, and puts them back.
    static func inline(_ text: String, image: (String) -> String? = { _ in nil }) -> String {
        var s = escape(text)
        var kept: [String] = []
        func keep(_ regex: NSRegularExpression, _ html: (NSTextCheckingResult, NSString) -> String) {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += "\u{1}\(kept.count)\u{1}"
                kept.append(html(m, ns))
                last = NSMaxRange(m.range)
            }
            s = result + ns.substring(from: last)
        }
        keep(codeSpan) { m, ns in "<code>\(ns.substring(with: m.range(at: 2)))</code>" }
        keep(link) { m, ns in
            let label = emphasize(ns.substring(with: m.range(at: 2)))
            let address = ns.substring(with: m.range(at: 3))
            if m.range(at: 1).length > 0 {
                return "<img src=\"\(image(address) ?? (safe(address) ? address : ""))\" alt=\"\(label)\">"
            }
            return safe(address) ? "<a href=\"\(address)\">\(label)</a>" : label
        }
        keep(bareURL) { m, ns in
            let url = ns.substring(with: m.range)
            return "<a href=\"\(url)\">\(url)</a>"
        }
        s = emphasize(s)
        // Newest first: a link's text can hold a code span set aside before it.
        for (i, html) in kept.enumerated().reversed() { s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: html) }
        return s
    }

    private static func emphasize(_ s: String) -> String {
        emphasis.reduce(s) { s, rule in
            rule.0.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: rule.1)
        }
    }

    /// Web, mail and in-page links, and relative paths; never javascript: or other schemes.
    static func safe(_ address: String) -> Bool {
        guard let colon = address.firstIndex(of: ":") else { return true }
        if address[..<colon].contains("/") || address[..<colon].contains("#") { return true }
        return ["http", "https", "mailto"].contains(address[..<colon].lowercased())
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A whole page in Deck's colors (CSS values like `#1a1a1a`).
    static func page(_ body: String, background: String, text: String, secondary: String, accent: String, fill: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { background: \(background); color: \(text); font: 15px/1.65 -apple-system, system-ui, sans-serif;
               max-width: 760px; margin: 0 auto; padding: 32px 36px 64px; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.5em; font-weight: 650; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: \(accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 0.88em ui-monospace, SFMono-Regular, Menlo, monospace; background: \(fill); padding: 0.15em 0.35em; border-radius: 5px; }
        pre { background: \(fill); padding: 14px 16px; border-radius: 10px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 0.86em; line-height: 1.55; }
        blockquote { border-left: 3px solid \(accent); padding: 2px 0 2px 16px; color: \(secondary); }
        blockquote > :last-child { margin-bottom: 0; }
        hr { border: none; border-top: 1px solid \(fill); margin: 2em 0; }
        ul, ol { padding-left: 1.5em; } li { margin: 0.2em 0; } li > ul, li > ol { margin: 0.2em 0; }
        li.task { list-style: none; margin-left: -1.4em; } li.task input { margin-right: 0.4em; accent-color: \(accent); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(fill); padding: 6px 12px; text-align: left; } th { background: \(fill); font-weight: 600; }
        img { max-width: 100%; border-radius: 8px; }
        del { color: \(secondary); }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}
