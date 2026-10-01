import Foundation

/// Your plan's usage limits, from `claude -p "/usage"`.
struct PlanUsage: Equatable {
    struct Limit: Equatable, Identifiable {
        let label: String    // "Current session", "Current week (all models)"
        let percent: Int
        let resets: String   // "Oct 6 at 1:29pm (Asia/Calcutta)"

        var id: String { label }

        /// "Current session" → "Session", "Current week (all models)" → "Week", "Current week (Fable)" → "Fable".
        var shortLabel: String {
            if let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
                let inner = String(label[label.index(after: open)..<close])
                return inner == "all models" ? "Week" : inner
            }
            return label.replacingOccurrences(of: "Current ", with: "").capitalized
        }
    }

    /// The current session limit, the one you'll hit first in practice.
    var session: Limit? { limits.first { $0.label.lowercased().contains("session") } ?? limits.first }

    let limits: [Limit]
    /// The explanatory lines ("What's contributing…"), as printed.
    let details: [String]
    /// The first line, e.g. "You are currently using your subscription…".
    let summary: String

    /// Parses lines like `Current week (Fable): 28% used · resets Oct 6 at 1:29pm (Asia/Calcutta)`.
    static func parse(_ output: String) -> PlanUsage {
        var limits: [Limit] = []
        var details: [String] = []
        var summary = ""
        for raw in Safety.stripANSI(output).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.range(of: #"^(.+?):\s*(\d+)% used(?:\s*·\s*resets\s*(.+))?$"#, options: .regularExpression) {
                let text = String(line[m])
                let colon = text.range(of: ":")!
                let label = String(text[..<colon.lowerBound])
                let rest = text[colon.upperBound...]
                let pct = Int(rest.drop { !$0.isNumber }.prefix { $0.isNumber })!
                let resets = rest.range(of: "resets ").map { String(rest[$0.upperBound...]) } ?? ""
                limits.append(Limit(label: label, percent: pct, resets: resets))
            } else if summary.isEmpty && limits.isEmpty && !line.isEmpty {
                summary = line
            } else if !limits.isEmpty {
                // Keep the indentation (it shows which lines belong under which heading).
                details.append(String(raw.reversed().drop { $0 == " " }.reversed()))
            }
        }
        while details.first?.isEmpty == true { details.removeFirst() }
        while details.last?.isEmpty == true { details.removeLast() }
        return PlanUsage(limits: limits, details: details, summary: summary)
    }
}
