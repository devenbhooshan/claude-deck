import Foundation

/// How the editor styles markdown as you type. The text stays plain markdown; each span says
/// what a stretch of it is (a heading, bold, a code span) or that it's syntax (`#`, `**`, `` ` ``),
/// drawn faint. Ranges are UTF-16, as text views count.
enum MarkdownSyntax {
    enum Kind: Equatable {
        /// A heading line, including its `#`s.
        case heading(Int)
        /// Syntax characters: `#`, `**`, `` ` ``, `>`, `[ ](…)`, code fences.
        case mark
        case bold, italic, strike
        /// Text inside a code span.
        case code
        /// A line inside a fenced code block, fences included.
        case codeBlock
        /// A link's text, and its address.
        case link, url
        /// A blockquote line.
        case quote
        /// `-`, `*`, `+` or `1.` starting a list item.
        case listMarker
        /// A task's `[ ]` or `[x]`.
        case task(done: Bool)
        /// A checked task's text.
        case done
        /// `---`
        case rule
        /// A table row.
        case table
    }

    struct Span: Equatable {
        let range: NSRange
        let kind: Kind
    }

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        var fence: String?
        var at = 0
        while at < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(lineRange)
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let content = NSRange(location: lineRange.location, length: (line as NSString).length)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                out.append(Span(range: content, kind: .codeBlock))
                if fence == nil { out.append(Span(range: content, kind: .mark)) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                out += [Span(range: content, kind: .codeBlock), Span(range: content, kind: .mark)]
                continue
            }
            out += block(line, at: content.location)
        }
        return out
    }

    static let heading = regex(#"^ {0,3}(#{1,6})(?:\s+(.*))?$"#)
    static let rule = regex(#"^ {0,3}([-*_])(?:\s*\1){2,}\s*$"#)
    static let quote = regex(#"^( {0,3}>\s?)(.*)$"#)
    /// A list item: indent, marker, space, an optional task box, then the text.
    static let listItem = regex(#"^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\]\s)?(.*)$"#)

    private static func block(_ line: String, at base: Int) -> [Span] {
        let full = NSRange(location: 0, length: (line as NSString).length)
        func r(_ range: NSRange) -> NSRange { NSRange(location: base + range.location, length: range.length) }
        if let m = heading.firstMatch(in: line, range: full) {
            let level = m.range(at: 1).length
            return [Span(range: r(full), kind: .heading(level)), Span(range: r(m.range(at: 1)), kind: .mark)]
                + inline(line, in: m.range(at: 2), base: base)
        }
        if rule.firstMatch(in: line, range: full) != nil { return [Span(range: r(full), kind: .rule)] }
        if let m = quote.firstMatch(in: line, range: full) {
            return [Span(range: r(full), kind: .quote), Span(range: r(m.range(at: 1)), kind: .mark)]
                + inline(line, in: m.range(at: 2), base: base)
        }
        if let m = listItem.firstMatch(in: line, range: full) {
            var out = [Span(range: r(m.range(at: 2)), kind: .listMarker)]
            let text = m.range(at: 5)
            let box = m.range(at: 4)
            if box.location != NSNotFound {
                let done = (line as NSString).substring(with: box).lowercased().hasPrefix("[x")
                out.append(Span(range: r(NSRange(location: box.location, length: 3)), kind: .task(done: done)))
                if done { out.append(Span(range: r(text), kind: .done)) }
            }
            return out + inline(line, in: text, base: base)
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            return [Span(range: r(full), kind: .table)] + inline(line, in: full, base: base)
        }
        return inline(line, in: full, base: base)
    }

    private static let codeSpan = regex(#"(`+)(.+?)\1"#)
    private static let link = regex(#"(!?\[)([^\]\n]*)(\]\()([^)\s]*)(\))"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])([*_])(?![*_\s])(.+?)(?<![*_\s])\1(?![*\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)

    /// Code spans first: nothing inside one is styled. Then links, bold, italic, strikethrough.
    private static func inline(_ line: String, in range: NSRange, base: Int) -> [Span] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        func r(_ range: NSRange) -> NSRange { NSRange(location: base + range.location, length: range.length) }
        var out: [Span] = []
        var code: [NSRange] = []
        for m in codeSpan.matches(in: line, range: range) {
            code.append(m.range)
            let ticks = m.range(at: 1).length
            out += [Span(range: r(m.range(at: 2)), kind: .code),
                    Span(range: r(NSRange(location: m.range.location, length: ticks)), kind: .mark),
                    Span(range: r(NSRange(location: NSMaxRange(m.range) - ticks, length: ticks)), kind: .mark)]
        }
        func free(_ m: NSTextCheckingResult) -> Bool { !code.contains { NSIntersectionRange($0, m.range).length > 0 } }
        for m in link.matches(in: line, range: range) where free(m) {
            out += [Span(range: r(m.range(at: 2)), kind: .link), Span(range: r(m.range(at: 4)), kind: .url)]
            out += [1, 3, 5].map { Span(range: r(m.range(at: $0)), kind: .mark) }
        }
        for (regex, kind) in [(bold, Kind.bold), (italic, .italic), (strike, .strike)] {
            for m in regex.matches(in: line, range: range) where free(m) {
                let marks = m.range(at: 1).length
                out += [Span(range: r(m.range(at: 2)), kind: kind),
                        Span(range: r(NSRange(location: m.range.location, length: marks)), kind: .mark),
                        Span(range: r(NSRange(location: NSMaxRange(m.range) - marks, length: marks)), kind: .mark)]
            }
        }
        return out
    }

    static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
}
