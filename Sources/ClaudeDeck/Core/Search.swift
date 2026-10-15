import Foundation

/// One searchable thing: something you asked, an activity event, or a session's title.
struct SearchDoc: Equatable {
    enum Kind: Equatable { case message, event(ActivityEvent.Kind), session }

    let id: String
    let sessionId: String
    let kind: Kind
    let at: Date?
    let text: String
    /// Where it is in the transcript (messages), to open the session right there.
    var offset: UInt64? = nil
}

struct SearchHit: Equatable {
    let doc: SearchDoc
    let score: Double
    /// How many of the searched words it contains.
    var matched: Int = 1
}

/// A session and its best matching moments.
struct SessionHit: Equatable {
    let sessionId: String
    var hits: [SearchHit]
    var first: Date?
    var last: Date?
    var score: Double
}

/// Keyword search (BM25) over everything Deck knows about your sessions. Built once per index
/// change, then each search only touches the words it asks for.
final class SearchIndex: @unchecked Sendable {
    let docs: [SearchDoc]
    private var postings: [String: [(doc: Int, tf: Int)]] = [:]
    private var lengths: [Int] = []
    private let averageLength: Double

    init(docs: [SearchDoc]) {
        self.docs = docs
        for (i, d) in docs.enumerated() {
            let words = Self.tokens(d.text)
            lengths.append(words.count)
            var counts: [String: Int] = [:]
            for w in words { counts[w, default: 0] += 1 }
            for (w, n) in counts { postings[w, default: []].append((i, n)) }
        }
        averageLength = Double(max(1, lengths.reduce(0, +))) / Double(max(1, docs.count))
    }

    /// Everything searchable in these sessions.
    static func documents(from sessions: [SessionActivity], extra: [ActivityEvent] = []) -> [SearchDoc] {
        let added = extra.map { e in
            SearchDoc(id: e.id, sessionId: e.sessionId, kind: .event(e.kind), at: e.at,
                      text: [e.label, e.title].compactMap { $0 }.joined(separator: " · "), offset: e.offset)
        }
        return added + sessions.flatMap { s -> [SearchDoc] in
            let x = s.extractor
            var out = x.asks.map { SearchDoc(id: $0.id, sessionId: s.sessionId, kind: .message, at: $0.at, text: $0.text, offset: $0.offset) }
            for e in ActivityIndex.browse(x.events) {
                let parts = [e.label, e.ref, e.repo, e.title, e.detail, e.quote].compactMap { $0 }
                out.append(SearchDoc(id: e.id, sessionId: s.sessionId, kind: .event(e.kind), at: e.at,
                                     text: parts.joined(separator: " · "), offset: e.offset))
            }
            if let title = x.title {
                out.append(SearchDoc(id: "\(s.sessionId):title", sessionId: s.sessionId, kind: .session,
                                     at: x.asks.first?.at ?? x.lastAt, text: title))
            }
            return out
        }
    }

    /// Index words one typo away (two for long words), for misspelled searches.
    private func nearby(_ w: String) -> [String] {
        guard w.count >= 4 else { return [] }
        let maxEdits = w.count >= 8 ? 2 : 1
        return postings.keys.filter { abs($0.count - w.count) <= maxEdits && Self.distance($0, w, limit: maxEdits) <= maxEdits }
            .sorted()
    }

    /// Edit distance (insert, delete, change, swap neighbours), giving up past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            var best = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                best = min(best, cur[j])
            }
            if best > limit { return best }
            prev2 = prev
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: - Words

    /// Stemmed word → stemmed words that mean the same in a coding log.
    static let synonyms: [String: [String]] = {
        let ship = ["merg", "merge", "push", "deploy", "releas", "release", "launch"]
        return ["ship": ship, "shipp": ship, "shipped": ship, "deliver": ship, "deliv": ship,
                "fix": ["bug", "bugfix", "hotfix"], "bug": ["fix"], "pr": ["pull"], "ticket": ["issue"], "issue": ["ticket"]]
    }()

    static let stopwords: Set<String> = [
        "a", "an", "the", "on", "in", "of", "to", "for", "and", "or", "is", "was", "were", "be", "it", "its", "that",
        "this", "with", "about", "at", "by", "from", "as", "i", "we", "my", "me", "you", "your", "our", "us",
        "which", "what", "when", "where", "who", "how", "why", "did", "do", "does", "can", "could", "should",
        "have", "has", "had", "any", "all", "some", "show", "find", "tell", "session", "sessions", "claude",
        "start", "started", "starting", "begin", "began", "first", "last", "latest", "recent", "recently",
        "work", "worked", "working", "please", "lets", "let", "just", "so", "then", "there", "here", "into",
    ]

    /// Lower-cased words without stopwords, lightly stemmed ("integrations" → "integration").
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) && !$0.isEmpty }
            .map(stem)
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4 else { return w }
        for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && !w.hasSuffix("ss") {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    // MARK: - Searching

    /// Ranked matches for these words. With `prefix`, the last word also matches longer words
    /// (search as you type). Phrases of several words count extra where they appear together.
    /// `matched` counts the `topic` words a hit contains (all words when no topic is given).
    func search(_ terms: [String], topic: [String]? = nil, prefix: Bool = false, since: Date? = nil, limit: Int = 200) -> [SearchHit] {
        let topicWords = Set((topic ?? terms).flatMap(Self.tokens))
        var scores: [Int: Double] = [:]
        var matched: [Int: Set<Int>] = [:]
        let n = Double(docs.count)
        var words: [String] = []
        for w in ((topic ?? []) + terms).flatMap(Self.tokens) where !words.contains(w) { words.append(w) }
        guard !words.isEmpty else { return [] }
        // Each searched word, as the words in the index that stand for it: itself, near-misses
        // (typos), and while typing, longer words starting with the last one.
        for (qi, w) in words.enumerated() {
            var variants: [(String, Double)] = postings[w] != nil ? [(w, 1)] : []
            if postings[w] == nil { variants += nearby(w).map { ($0, 0.8) } }
            // Words that mean the same thing in a coding log ("shipped" → merged, pushed, deployed).
            variants += (Self.synonyms[w] ?? []).filter { postings[$0] != nil }.map { ($0, 0.8) }
            if prefix, qi == words.count - 1 {
                variants += postings.keys.filter { $0.hasPrefix(w) && $0 != w }.sorted().prefix(30).map { ($0, 0.6) }
            }
            for (v, weight) in variants {
                let list = postings[v]!
                let idf = log(1 + (n - Double(list.count) + 0.5) / (Double(list.count) + 0.5))
                for (doc, tf) in list {
                    let k = 1.2, b = 0.75
                    let norm = Double(tf) * (k + 1) / (Double(tf) + k * (1 - b + b * Double(lengths[doc]) / averageLength))
                    scores[doc, default: 0] += idf * norm * weight
                    if topicWords.contains(w) { matched[doc, default: []].insert(qi) }
                }
            }
        }
        let phrases = terms.map { $0.lowercased() }.filter { $0.contains(" ") }
        return scores.compactMap { i, s -> SearchHit? in
            let d = docs[i]
            if let since, (d.at ?? .distantPast) < since { return nil }
            let text = d.text.lowercased()
            let bonus = phrases.filter { text.contains($0) }.count
            return SearchHit(doc: d, score: s * (1 + 0.5 * Double(bonus)), matched: matched[i]?.count ?? 0)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.doc.id < $1.doc.id }
        .prefix(limit).map { $0 }
    }
}

/// Turning a question into a search, ranking sessions, and the Haiku prompts for the rest.
enum SessionSearch {
    enum Order: String, Codable { case first, latest, all }

    /// What the words alone say: the search terms, and whether you want the first or latest time.
    /// Time words become a date filter rather than words to match ("what shipped today" searches
    /// "shipped" in today's activity).
    static func plain(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> (terms: [String], order: Order, since: Date?) {
        let q = question.lowercased()
        let words = Set(q.split { !$0.isLetter }.map(String.init))
        let today = calendar.startOfDay(for: now)
        let windows: [(phrase: String, since: Date)] = [
            ("last week", today.addingTimeInterval(-7 * 86400)), ("this week", today.addingTimeInterval(-7 * 86400)),
            ("this month", today.addingTimeInterval(-30 * 86400)), ("last month", today.addingTimeInterval(-30 * 86400)),
            ("yesterday", today.addingTimeInterval(-86400)), ("today", today), ("tonight", today),
        ]
        var rest = q, since: Date?
        for w in windows where rest.contains(w.phrase) {
            since = min(since ?? w.since, w.since)
            rest = rest.replacingOccurrences(of: w.phrase, with: " ")
        }
        let order: Order = !words.isDisjoint(with: ["start", "started", "begin", "began", "first", "initially", "kicked"]) ? .first
            : !words.isDisjoint(with: ["latest", "recent", "recently", "lately"]) || (words.contains("last") && since == nil) ? .latest : .all
        return ([rest], order, since)
    }

    /// Sessions ranked for the question: the earliest (or latest) time it came up, or by how well
    /// they match. Weak matches (under a third of the best) are left out.
    static func sessions(_ hits: [SearchHit], order: Order, limit: Int = 20) -> [SessionHit] {
        // Only moments with the whole topic (or as much of it as any has) count, so a partial
        // match ("rails integration", or "app" from "app sumo") can't crowd in or win "first".
        let coverage = hits.map(\.matched).max() ?? 0
        let pool = hits.filter { $0.matched == coverage }
        guard let top = pool.map(\.score).max() else { return [] }
        let relevant = pool.filter { $0.score >= top / 3 }
        var bySession: [String: SessionHit] = [:]
        for h in relevant {
            var s = bySession[h.doc.sessionId] ?? SessionHit(sessionId: h.doc.sessionId, hits: [], first: nil, last: nil, score: 0)
            s.hits.append(h)
            if let at = h.doc.at {
                s.first = min(s.first ?? at, at)
                s.last = max(s.last ?? at, at)
            }
            s.score = max(s.score, h.score)
            bySession[h.doc.sessionId] = s
        }
        var out = Array(bySession.values)
        for i in out.indices {
            // Show the moments in time order for first/latest, else the best ones.
            out[i].hits.sort { a, b in
                switch order {
                case .first: (a.doc.at ?? .distantFuture) < (b.doc.at ?? .distantFuture)
                case .latest: (a.doc.at ?? .distantPast) > (b.doc.at ?? .distantPast)
                case .all: a.score > b.score
                }
            }
            out[i].hits = Array(out[i].hits.prefix(3))
        }
        // One sort key per session (undated ones last), ties broken by id so the order never flickers.
        let keyed = out.map { s -> (key: Double, hit: SessionHit) in
            switch order {
            case .first: ((s.first ?? .distantFuture).timeIntervalSince1970, s)
            case .latest: (-(s.last ?? .distantPast).timeIntervalSince1970, s)
            case .all: (-s.score, s)
            }
        }
        return keyed.sorted { ($0.key, $0.hit.sessionId) < ($1.key, $1.hit.sessionId) }.prefix(limit).map(\.hit)
    }

    // MARK: - Asking Claude Haiku

    struct Intent: Equatable {
        /// What it's about: words a moment must have.
        var topic: [String]
        /// Other spellings and related words: they help ranking, but aren't required.
        var related: [String]
        var order: Order
        var sinceDays: Int?
    }

    static let intentSchema = #"{"type":"object","properties":{"topic":{"type":"array","items":{"type":"string"}},"related":{"type":"array","items":{"type":"string"}},"order":{"type":"string","enum":["first","latest","all"]},"since_days":{"type":["integer","null"]}},"required":["topic","related","order"]}"#

    static func intentPrompt(_ question: String) -> String {
        """
        A developer is searching the history of their coding-agent sessions (their own chat messages, \
        PR and ticket titles, commit messages, branch names). Turn the question into a keyword search.
        - topic: the 1 to 3 words the subject is named by, spelled correctly (fix typos). Every result must contain these.
        - related: up to 6 other spellings, abbreviations or names for the same subject (not generic \
        words like "api", "fix" or "code").
        - order: "first" if they ask when something started or the first time, "latest" for the most \
        recent time, else "all".
        - since_days: only if they name a time window ("last week" = 7), else null.

        Question: \(question)
        """
    }

    static func parseIntent(_ output: String) -> Intent? {
        func words(_ key: String) -> [String] {
            ((obj?[key] as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let obj = ActivitySummarizer.structured(output)
        let topic = words("topic")
        guard !topic.isEmpty, let order = (obj?["order"] as? String).flatMap(Order.init(rawValue:)) else { return nil }
        let days = (obj?["since_days"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return Intent(topic: Array(topic.prefix(3)), related: Array(words("related").prefix(6)), order: order, sinceDays: days)
    }

    static let answerSchema = #"{"type":"object","properties":{"answer":{"type":"string"},"picks":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"why":{"type":"string"}},"required":["id","why"]}}},"required":["answer","picks"]}"#

    /// The question and the best moments found, for Haiku to answer from.
    static func answerPrompt(_ question: String, order: Order, sessions: [SessionHit], title: (String) -> String,
                             timeZone: TimeZone = .current) -> String {
        // Local times, written the way the developer reads them.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE, MMM d yyyy, h:mm a"
        let moments: [[String: String]] = sessions.flatMap { s in
            s.hits.map { h in
                ["id": h.doc.id, "session": title(s.sessionId), "time": h.doc.at.map { f.string(from: $0) } ?? "unknown",
                 "text": String(h.doc.text.prefix(300))]
            }
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: moments, options: [.sortedKeys]), encoding: .utf8)!
        return """
            Answer the developer's question about their coding-agent sessions using only these moments \
            (their messages, and things their sessions did). \(order == .first ? "They want the earliest one." : order == .latest ? "They want the most recent one." : "")
            - answer: one short sentence, e.g. "You started it in “supergrow” on Thu, Oct 15 at 11:13 AM." \
            Name the session and the time as given. No ids. If nothing fits, say so.
            - picks: the ids of the moments that answer it, best first (at most 5), each with a short reason.

            Question: \(question)
            Moments:
            \(json)
            """
    }

    /// The answer and the picked moments (only ids that were offered).
    static func parseAnswer(_ output: String, ids: Set<String>) -> (answer: String, picks: [(id: String, why: String)])? {
        guard let obj = ActivitySummarizer.structured(output),
              let answer = (obj["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty
        else { return nil }
        let picks = (obj["picks"] as? [[String: Any]] ?? []).compactMap { p -> (id: String, why: String)? in
            guard let id = p["id"] as? String, ids.contains(id) else { return nil }
            return (id, (p["why"] as? String) ?? "")
        }
        return (String(answer.prefix(600)), Array(picks.prefix(5)))
    }
}
