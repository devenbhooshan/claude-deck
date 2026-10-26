import Foundation

/// Claude's replies as blocks, parsed by Foundation's markdown parser (CommonMark plus tables), so
/// any standard construct is recognised rather than shown as raw syntax. Inline styling (bold,
/// code, links) stays on each block's text for the renderer.
enum Markdown {
    struct Block: Equatable {
        enum Kind: Equatable {
            case paragraph(AttributedString)
            case heading(AttributedString, level: Int)
            case code(String)
            /// Rows of cells, the header row first.
            case table([[AttributedString]])
            case rule
        }

        var kind: Kind
        /// How many quotes it's inside.
        var quoteDepth = 0
        /// How many lists it's inside (0: not in a list).
        var listDepth = 0
        /// The first paragraph of a list item: "•", "3.", or a task's "☐" / "☑".
        var marker: String? = nil
    }

    static func parse(_ text: String, parser: (String) throws -> AttributedString = parseFull) -> [Block] {
        // If the markdown can't be parsed, show the raw text.
        let doc = (try? parser(text)) ?? AttributedString(text)
        var blocks: [Block] = []
        // The identity of the block (or table cell, row and table) the last run belonged to.
        var leaf: Int?
        var row: Int?
        var table: Int?
        var items: Set<Int> = []

        for run in doc.runs {
            let piece = AttributedString(doc[run.range])
            let parts = run.presentationIntent?.components ?? []
            guard let first = parts.first else {
                // Raw HTML: shown as written.
                let raw = String(piece.characters).trimmingCharacters(in: .newlines)
                if !raw.isEmpty { blocks.append(Block(kind: .paragraph(AttributedString(raw)))) }
                leaf = nil
                continue
            }
            if first.identity == leaf, let last = blocks.indices.last {
                blocks[last].kind.append(piece)
                continue
            }
            if case .tableCell = first.kind, parts.count >= 3 {
                if parts[2].identity != table {
                    blocks.append(Block(kind: .table([[piece]])))
                } else {
                    blocks[blocks.count - 1].kind.addCell(piece, newRow: parts[1].identity != row)
                }
                (leaf, row, table) = (first.identity, parts[1].identity, parts[2].identity)
                continue
            }
            table = nil
            leaf = first.identity

            var block = Block(kind: .rule)
            switch first.kind {
            case .header(let level): block.kind = .heading(piece, level: level)
            case .codeBlock: block.kind = .code(String(piece.characters))
            case .thematicBreak: block.kind = .rule
            default: block.kind = .paragraph(piece)
            }
            block.quoteDepth = parts.filter { $0.kind == .blockQuote }.count
            let listItems = parts.enumerated().compactMap { i, p -> (ordinal: Int, item: Int, ordered: Bool)? in
                guard case .listItem(let ordinal) = p.kind else { return nil }
                return (ordinal, p.identity, i + 1 < parts.count && parts[i + 1].kind == .orderedList)
            }
            block.listDepth = listItems.count
            if let item = listItems.first, items.insert(item.item).inserted {
                block.marker = item.ordered ? "\(item.ordinal)." : "•"
            }
            blocks.append(block)
        }
        return blocks.map(finish)
    }

    static func parseFull(_ text: String) throws -> AttributedString {
        try AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    }

    /// Trailing newlines off code; `[ ]` / `[x]` at the start of a list item become a checkbox.
    private static func finish(_ block: Block) -> Block {
        var b = block
        switch b.kind {
        case .code(let c):
            b.kind = .code(c.replacingOccurrences(of: "\n$", with: "", options: .regularExpression))
        case .paragraph(let p) where b.marker == "•":
            let start = String(p.characters.prefix(4))
            guard ["[ ] ", "[x] ", "[X] "].contains(start) else { break }
            b.marker = start == "[ ] " ? "☐" : "☑"
            b.kind = .paragraph(AttributedString(p[p.index(p.startIndex, offsetByCharacters: 4)...]))
        default: break
        }
        return b
    }
}

private extension Markdown.Block.Kind {
    /// More text of the same paragraph, heading or table cell (a run with different styling).
    /// Code and rules are always one run.
    mutating func append(_ piece: AttributedString) {
        if case .paragraph(var p) = self {
            p.append(piece)
            self = .paragraph(p)
        } else if case .heading(var h, let level) = self {
            h.append(piece)
            self = .heading(h, level: level)
        } else if case .table(var rows) = self {
            rows[rows.count - 1][rows[rows.count - 1].count - 1].append(piece)
            self = .table(rows)
        }
    }

    mutating func addCell(_ piece: AttributedString, newRow: Bool) {
        if case .table(var rows) = self {
            if newRow { rows.append([]) }
            rows[rows.count - 1].append(piece)
            self = .table(rows)
        }
    }
}
