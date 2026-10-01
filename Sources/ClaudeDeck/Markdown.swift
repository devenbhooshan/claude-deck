import Foundation

/// Lightweight block markdown: fenced code, headings, tables, lists and paragraphs.
/// Inline styling (bold, code, links) is applied by the renderer.
enum Markdown {
    enum Block {
        case code(String)
        case heading(String, level: Int)
        case paragraph(String)
        case table([[String]])
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String]?
        var table: [[String]] = []

        func flushParagraph() {
            let p = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { blocks.append(.paragraph(p)) }
            para = []
        }

        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code {
                    blocks.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    flushTable()
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(line); continue }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flushParagraph() }
                let row = cells(trimmed)
                // Skip the |---|:---:| separator row.
                if !row.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) {
                    table.append(row)
                }
                continue
            }
            flushTable()
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                flushParagraph()
                blocks.append(.heading(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(repeating: "   ", count: (line.count - line.drop { $0 == " " }.count) / 2)
                para.append(indent + "•  " + trimmed.dropFirst(2))
            } else {
                para.append(line)
            }
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flushTable()
        flushParagraph()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var r = Substring(row)
        if r.hasPrefix("|") { r = r.dropFirst() }
        if r.hasSuffix("|") { r = r.dropLast() }
        return r.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
