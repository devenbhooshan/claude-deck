import Foundation

/// Something a session did that's worth seeing at a glance: a PR or ticket it touched, or a
/// screenshot it looked at. Inferred from what Claude ran, and labelled by exactly that.
struct ActivityEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case openedPR, mergedPR, reviewedPR, commentedPR, viewedPR, linkedPR
        case createdTicket, updatedTicket, commentedTicket, viewedTicket, mentionedTicket
        case screenshot
    }

    var id: String
    var sessionId: String
    var kind: Kind
    var at: Date?
    /// The git branch the session was on.
    var branch: String?
    /// PRs: "owner/name" when known, and the number.
    var repo: String?
    var number: Int?
    /// Tickets: the identifier, e.g. "SUP-610".
    var ticket: String?
    var url: String?
    /// The folder a `gh` command ran in, to look the PR up from (its repo isn't always named).
    var dir: String?
    var title: String?
    /// e.g. "Approved", or what a screenshot showed.
    var detail: String?
    var count: Int = 1
    /// Claude's own words right after it: the summary until an AI one is written.
    var narration: String?

    var isPR: Bool { number != nil || [.openedPR, .mergedPR, .reviewedPR, .commentedPR, .viewedPR, .linkedPR].contains(kind) }
    var isTicket: Bool { ticket != nil }

    /// Identifies the PR across events ("owner/name#12", or "#12" when the repo isn't known).
    var prKey: String? { number.map { "\(repo ?? "")#\($0)" } }

    var label: String {
        switch kind {
        case .openedPR: "Opened PR"
        case .mergedPR: "Merged PR"
        case .reviewedPR: "Reviewed PR"
        case .commentedPR: "Commented on PR"
        case .viewedPR: "Looked at PR"
        case .linkedPR: "Linked PR"
        case .createdTicket: "Created ticket"
        case .updatedTicket: "Updated ticket"
        case .commentedTicket: "Commented on ticket"
        case .viewedTicket: "Looked at ticket"
        case .mentionedTicket: "Ticket"
        case .screenshot: count > 1 ? "Reviewed \(count) screenshots" : "Reviewed a screenshot"
        }
    }

    /// A title without the ref it starts with ("SUP-610: Approval flow" → "Approval flow").
    static func trimmed(_ title: String, ref: String?) -> String {
        guard let ref, title.lowercased().hasPrefix(ref.lowercased()) else { return title }
        let rest = title.dropFirst(ref.count).drop { " :-–—|".contains($0) }
        return rest.isEmpty ? title : String(rest)
    }

    /// A ticket's Linear link, built from any Linear link seen (which names the workspace).
    static func linearURL(for ticket: String, in events: [ActivityEvent]) -> String? {
        for e in events {
            if let url = e.url, let m = Rx.first(#"^https://linear\.app/([\w-]+)/issue/"#, in: url) {
                return "https://linear.app/\(m[1]!)/issue/\(ticket)"
            }
        }
        return nil
    }

    /// "#188", "SUP-610", or nothing for screenshots.
    var ref: String? {
        if let ticket { return ticket }
        return number.map { "#\($0)" }
    }

    /// The first real sentence of Claude's narration (at least four words, so not "Done.").
    var quote: String? {
        guard let text = narration else { return nil }
        for sentence in Self.sentences(text) where sentence.split(separator: " ").count >= 4 {
            return sentence.count > 180 ? String(sentence.prefix(179)) + "…" : sentence
        }
        return nil
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                out.append(current); current = ""
                continue
            }
            current.append(c)
            if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\n" {
                out.append(current); current = ""
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// What a session is on right now: the ticket and PR of its branch, or else the latest ones it
/// touched in its recent activity (work often happens on other branches or in worktrees).
struct CurrentWork: Equatable {
    var ticket: String?
    var ticketTitle: String?
    var pr: ActivityEvent?

    /// Branches that are never "working on" anything in particular.
    static let trunkBranches: Set<String> = ["main", "master", "dev", "develop", "staging", "production", "HEAD", ""]
    static let prKinds: Set<ActivityEvent.Kind> = [.openedPR, .mergedPR, .reviewedPR, .commentedPR]

    static func of(events: [ActivityEvent], branch: String?, window: TimeInterval = 12 * 3600) -> CurrentWork? {
        let onBranch = branch.flatMap { trunkBranches.contains($0) ? nil : $0 }
        let latest = events.compactMap(\.at).max() ?? .distantPast
        let recent = events.filter { ($0.at ?? .distantPast) >= latest.addingTimeInterval(-window) }
        let ticket = onBranch.flatMap(ticketId) ?? recent.last(where: \.isTicket)?.ticket
        // On its branch, a linked PR counts; otherwise only PRs the session acted on.
        let pr = onBranch.flatMap { b in events.last { ($0.kind == .linkedPR || prKinds.contains($0.kind)) && $0.branch == b && $0.number != nil } }
            ?? recent.last { prKinds.contains($0.kind) && $0.number != nil }
        if ticket == nil && pr == nil { return nil }
        let ticketTitle = ticket.flatMap { t in
            events.last { $0.ticket == t && $0.title != nil }?.title ?? events.last { $0.title?.contains(t) == true }?.title
        }
        return CurrentWork(ticket: ticket, ticketTitle: ticketTitle, pr: pr)
    }

    /// "deven/sup-610-approval-workflow" → "SUP-610".
    static func ticketId(fromBranch branch: String) -> String? {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        guard let m = Rx.first(#"^([A-Za-z]{2,6})-(\d+)(?:-|$)"#, in: last) else { return nil }
        return "\(m[1]!.uppercased())-\(m[2]!)"
    }
}

/// Reads a transcript line by line (as it grows) and turns what Claude did into events. Only
/// lines that might matter are decoded, so even huge transcripts index quickly. Its state is
/// Codable so indexing can resume where it left off.
struct ActivityExtractor: Codable {
    let sessionId: String
    private(set) var events: [ActivityEvent] = []
    private(set) var branch: String?
    private(set) var cwd: String?
    /// Where Claude's shell is: it keeps its folder between commands until Claude Code resets it.
    private var shellDir: String?
    private(set) var lastAt: Date?
    private var customTitle: String?
    private var aiTitle: String?
    /// Tool calls waiting for their result: their events are kept only if the call succeeded.
    private var pending: [String: [String]] = [:]
    /// Events still collecting Claude's narration (until your next message).
    private var narrating: [String] = []
    /// Counts your messages, so screenshots within one turn become one event.
    private var turn = 0
    private var lastScreenshot: (id: String, turn: Int)? {
        get { lastScreenshotId.map { ($0, lastScreenshotTurn) } }
        set { lastScreenshotId = newValue?.id; lastScreenshotTurn = newValue?.turn ?? 0 }
    }
    private var lastScreenshotId: String?
    private var lastScreenshotTurn = 0
    private var seq = 0

    init(sessionId: String) { self.sessionId = sessionId }

    var title: String? { customTitle ?? aiTitle }

    static let maxNarration = 700

    private static let needles: [[UInt8]] = [
        "gh pr ", "gh api", "Linear__", "\"pr-link\"", "screenshot", "\"name\":\"Read\"", "linear.app/",
        "command-name>/review", "command-name>/code-review", "\"ai-title\"", "\"custom-title\"", "\"type\":\"image\"",
    ].map { Array($0.utf8) }
    private static let branchKey = Array("\"gitBranch\":\"".utf8)
    private static let cwdKey = Array("\"cwd\":\"".utf8)
    private static let toolUseIdKey = Array("\"tool_use_id\"".utf8)
    private static let assistantKey = Array("\"type\":\"assistant\"".utf8)
    private static let userKey = Array("\"type\":\"user\"".utf8)
    private static let shellResetKey = Array("Shell cwd was reset to ".utf8)

    mutating func ingest(_ line: Data) {
        if let b = Bytes.value(after: Self.branchKey, in: line) { branch = b }
        if cwd == nil, let c = Bytes.value(after: Self.cwdKey, in: line) { cwd = c }
        if let reset = Bytes.value(after: Self.shellResetKey, in: line, until: [UInt8(ascii: "\""), UInt8(ascii: "\\")]) {
            shellDir = reset
        }
        let wanted = Self.needles.contains { Bytes.contains(line, $0) }
            || (!pending.isEmpty && Bytes.contains(line, Self.toolUseIdKey))
            || (!narrating.isEmpty && (Bytes.contains(line, Self.assistantKey) || Bytes.contains(line, Self.userKey)))
        guard wanted, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let at = (obj["timestamp"] as? String).flatMap(Rx.date)
        if let at { lastAt = at }
        switch obj["type"] as? String {
        case "pr-link": prLink(obj, at: at)
        case "ai-title": aiTitle = obj["aiTitle"] as? String ?? aiTitle
        case "custom-title": customTitle = obj["customTitle"] as? String ?? customTitle
        case "assistant": assistant(obj, at: at)
        case "user": user(obj, at: at)
        default: break
        }
    }

    // MARK: - Records

    private mutating func prLink(_ obj: [String: Any], at: Date?) {
        guard let n = obj["prNumber"] as? Int else { return }
        let repo = obj["prRepository"] as? String
        guard !events.contains(where: { $0.number == n && ($0.repo == nil || $0.repo == repo) }) else { return }
        add(.linkedPR, at: at) { $0.number = n; $0.repo = repo; $0.url = obj["prUrl"] as? String }
    }

    private mutating func assistant(_ obj: [String: Any], at: Date?) {
        guard let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for block in content {
            switch block["type"] as? String {
            case "text": narrate(block["text"] as? String ?? "")
            case "tool_use": toolUse(block, at: at)
            default: break
            }
        }
    }

    private mutating func user(_ obj: [String: Any], at: Date?) {
        if obj["isMeta"] as? Bool == true { return }
        let content = (obj["message"] as? [String: Any])?["content"]
        if let text = content as? String {
            humanMessage(text: text, images: 0, at: at)
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        var text = "", images = 0, results = false
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                results = true
                toolResult(block)
            case "text": text += (block["text"] as? String ?? "") + "\n"
            case "image": images += 1
            default: break
            }
        }
        if !results { humanMessage(text: text, images: images, at: at) }
    }

    /// Your message: ends the previous turn's narration, and may mention a ticket, ask for a
    /// review, or share screenshots.
    private mutating func humanMessage(text: String, images: Int, at: Date?) {
        turn += 1
        narrating = []
        for m in Rx.all(#"linear\.app/([\w-]+)/issue/([A-Za-z]+-\d+)"#, in: text) {
            let id = m[2]!.uppercased(), url = "https://linear.app/\(m[1]!)/issue/\(id)"
            if !events.contains(where: { $0.ticket == id }) {
                add(.mentionedTicket, at: at) { $0.ticket = id; $0.url = url }
            }
        }
        if let cmd = Rx.first(#"<command-name>/(?:review|code-review)</command-name>\s*<command-args>([^<]*)</command-args>"#, in: text) {
            let (repo, number) = Self.prRef(in: cmd[1]!)
            let dir = cwd
            if let number {
                add(.reviewedPR, at: at, narrate: true) { $0.number = number; $0.repo = repo; $0.dir = dir }
            }
        }
        if images > 0 {
            add(.screenshot, at: at, narrate: true) { $0.count = images; $0.detail = images > 1 ? "Images you shared" : "An image you shared" }
            lastScreenshot = (events.last!.id, turn)
        }
    }

    private mutating func toolUse(_ block: [String: Any], at: Date?) {
        guard let name = block["name"] as? String, let id = block["id"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        var created: [String] = []
        if name == "Bash", let command = input["command"] as? String {
            created = bash(command, at: at)
        } else if let range = name.range(of: "Linear__") {
            created = linear(String(name[range.upperBound...]), input, at: at)
        } else if Self.isScreenshot(name: name, input: input) {
            created = screenshot(detail: Self.imageName(name: name, input: input), at: at)
        }
        if !created.isEmpty { pending[id] = created }
    }

    private mutating func toolResult(_ block: [String: Any]) {
        guard let id = block["tool_use_id"] as? String, let ids = pending.removeValue(forKey: id) else { return }
        if block["is_error"] as? Bool == true {
            events.removeAll { ids.contains($0.id) }
            if let shot = lastScreenshot, ids.contains(shot.id) { lastScreenshot = nil }
            return
        }
        let text = Self.text(of: block["content"])
        for eid in ids {
            guard let i = events.firstIndex(where: { $0.id == eid }) else { continue }
            fill(&events[i], from: text)
            if !narrating.contains(eid) { narrating.append(eid) }
        }
    }

    /// Details only the result has: a new PR's number, a ticket's title, a screenshot's page.
    private func fill(_ e: inout ActivityEvent, from text: String) {
        if e.isTicket, let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            if let id = json["identifier"] as? String ?? json["id"] as? String, Rx.first(#"^[A-Z]+-\d+$"#, in: id) != nil { e.ticket = id }
            e.title = json["title"] as? String ?? e.title
            e.url = json["url"] as? String ?? e.url
        } else if e.kind == .openedPR, let m = Rx.first(#"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"#, in: text) {
            e.repo = m[1]; e.number = Int(m[2]!); e.url = m[0]
        } else if e.kind == .screenshot, e.detail == nil,
                  let tab = Rx.first(#"Executed on tabId: (\d+)"#, in: text),
                  let page = Rx.first(#"tabId \#(tab[1]!): "([^"]*)" \("([^"]*)"\)"#, in: text) {
            e.detail = page[1]!.isEmpty ? page[2] : "\(page[1]!) · \(page[2]!)"
        }
    }

    private mutating func narrate(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        for id in narrating {
            guard let i = events.firstIndex(where: { $0.id == id }) else { continue }
            let current = events[i].narration ?? ""
            guard current.count < Self.maxNarration else { continue }
            let joined = current.isEmpty ? t : current + "\n" + t
            events[i].narration = String(joined.prefix(Self.maxNarration))
        }
    }

    // MARK: - Tools

    /// `gh pr <verb>` (possibly several in one command) and review / comment posts via `gh api`.
    /// Only commands actually run count: each must start a command segment, so a script or a
    /// grep that merely mentions `gh pr merge` doesn't.
    private mutating func bash(_ command: String, at: Date?) -> [String] {
        typealias Found = (kind: ActivityEvent.Kind, repo: String?, number: Int?, title: String?, detail: String?, dir: String?)
        var found: [Found] = []
        var dir = shellDir
        defer { shellDir = dir }
        var vars: [String: String] = [:]
        for segment in Self.withoutHeredocs(command).split(whereSeparator: { "\n;|&".contains($0) }) {
            var t = segment.trimmingCharacters(in: .whitespaces)
            // Simple variables set earlier in the command (R=owner/repo; gh pr merge 1 -R $R).
            for (name, value) in vars {
                t = t.replacingOccurrences(of: "${\(name)}", with: value).replacingOccurrences(of: "$\(name)", with: value)
            }
            if let v = Rx.first(#"^(?:export\s+)?([A-Za-z_]\w*)=(?:"([^"]*)"|'([^']*)'|(\S*))$"#, in: t) {
                vars[v[1]!] = v[2] ?? v[3] ?? v[4]!
            } else if let cd = Rx.first(#"^cd\s+(?:"([^"]+)"|'([^']+)'|(\S+))"#, in: t) {
                dir = ((cd[1] ?? cd[2] ?? cd[3])! as NSString).expandingTildeInPath
            } else if let m = Rx.first(#"^gh\s+pr\s+(create|merge|review|comment|view|diff|checkout)\b(.*)$"#, in: t) {
                let verb = m[1]!, args = m[2]!
                var (repo, number) = Self.prRef(in: args)
                // A new PR's number comes from the result (a number in its title isn't one).
                if verb == "create" { number = nil; repo = nil }
                repo = repo ?? Rx.first(#"(?:--repo|-R)[ =]([\w.-]+/[\w.-]+)"#, in: args)?[1]
                let kind: ActivityEvent.Kind = switch verb {
                case "create": .openedPR
                case "merge": .mergedPR
                case "review": .reviewedPR
                case "comment": .commentedPR
                default: .viewedPR
                }
                if number == nil, kind != .openedPR {
                    // No number: the PR of the current branch, if this session made or linked one.
                    guard let current = events.last(where: { [.openedPR, .linkedPR].contains($0.kind) && $0.branch == branch && $0.number != nil })
                    else { continue }
                    number = current.number; repo = repo ?? current.repo
                }
                var title: String?, detail: String?
                if kind == .openedPR, let t = Rx.first(#"--title[ =](?:"([^"]*)"|'([^']*)')"#, in: args) { title = t[1] ?? t[2] }
                if kind == .reviewedPR {
                    detail = args.contains("--approve") ? "Approved" : args.contains("--request-changes") ? "Requested changes" : "Commented"
                }
                found.append((kind, repo, number, title, detail, dir))
            } else if let m = Rx.first(#"^gh\s+api\b.*repos/([\w.-]+/[\w.-]+)/pulls/(\d+)/(reviews|comments)"#, in: t),
                      Rx.first(#"(?:-X|--method)\s*POST|\s-[fF]\s|--input\b"#, in: t) != nil {
                found.append((m[3] == "reviews" ? .reviewedPR : .commentedPR, m[1], Int(m[2]!), nil, nil, dir))
            }
        }
        // One event per PR per command: the strongest thing done to it.
        let rank: [ActivityEvent.Kind] = [.mergedPR, .openedPR, .reviewedPR, .commentedPR, .viewedPR]
        var best: [String: Found] = [:]
        var order: [String] = []
        for f in found {
            let key = f.number.map { "#\($0)" } ?? "new\(order.count)"
            if let existing = best[key] {
                if rank.firstIndex(of: f.kind)! < rank.firstIndex(of: existing.kind)! { best[key] = f }
            } else {
                best[key] = f
                order.append(key)
            }
        }
        var ids: [String] = []
        let sessionDir = cwd
        for key in order {
            let f = best[key]!
            // Looking at a PR again isn't news.
            if f.kind == .viewedPR, events.contains(where: { $0.number == f.number }) { continue }
            // Something real done to a PR replaces merely linking or looking at it.
            if let n = f.number, f.kind != .viewedPR {
                events.removeAll { ($0.kind == .linkedPR || $0.kind == .viewedPR) && $0.number == n }
            }
            ids.append(add(f.kind, at: at) {
                $0.repo = f.repo
                $0.number = f.number
                $0.title = f.title
                $0.detail = f.detail
                $0.dir = f.dir ?? sessionDir
            })
        }
        return ids
    }

    private mutating func linear(_ tool: String, _ input: [String: Any], at: Date?) -> [String] {
        let id = (input["id"] as? String ?? input["issueId"] as? String).map { $0.uppercased() }
        let kind: ActivityEvent.Kind
        switch tool {
        case "get_issue": kind = .viewedTicket
        case "save_issue": kind = id == nil ? .createdTicket : .updatedTicket
        case "save_comment": kind = .commentedTicket
        default: return []
        }
        if kind == .viewedTicket, let id, events.contains(where: { $0.ticket == id }) { return [] }
        return [add(kind, at: at) {
            $0.ticket = id ?? "Ticket"
            $0.title = input["title"] as? String
        }]
    }

    /// Screenshots within one turn become a single event.
    private mutating func screenshot(detail: String?, at: Date?) -> [String] {
        if let shot = lastScreenshot, shot.turn == turn, let i = events.firstIndex(where: { $0.id == shot.id }) {
            events[i].count += 1
            return [shot.id]
        }
        let id = add(.screenshot, at: at) { $0.detail = detail }
        lastScreenshot = (id, turn)
        return [id]
    }

    // MARK: - Helpers

    @discardableResult
    private mutating func add(_ kind: ActivityEvent.Kind, at: Date?, narrate: Bool = false,
                              _ configure: (inout ActivityEvent) -> Void) -> String {
        seq += 1
        var e = ActivityEvent(id: "\(sessionId):\(seq)", sessionId: sessionId, kind: kind, at: at, branch: branch)
        configure(&e)
        if e.url == nil, let repo = e.repo, let n = e.number { e.url = "https://github.com/\(repo)/pull/\(n)" }
        events.append(e)
        if narrate { narrating.append(e.id) }
        return e.id
    }

    /// The command with heredoc bodies (scripts, PR descriptions) taken out: they're input, not commands.
    static func withoutHeredocs(_ command: String) -> String {
        let re = try! NSRegularExpression(pattern: #"<<-?\s*['"]?(\w+)['"]?([^\n]*)\n[\s\S]*?\n\s*\1(?=\s|\)|$)"#)
        let ns = command as NSString
        return re.stringByReplacingMatches(in: command, range: NSRange(location: 0, length: ns.length), withTemplate: "$2")
    }

    /// A PR number or URL in some arguments.
    static func prRef(in args: String) -> (repo: String?, number: Int?) {
        if let m = Rx.first(#"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"#, in: args) { return (m[1], Int(m[2]!)) }
        if let m = Rx.first(#"(?:^|\s)#?(\d+)(?=\s|$)"#, in: args) { return (nil, Int(m[1]!)) }
        return (nil, nil)
    }

    static func isScreenshot(name: String, input: [String: Any]) -> Bool {
        if name == "Read", let path = input["file_path"] as? String {
            return ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
        }
        return input["action"] as? String == "screenshot" || name.hasSuffix("screenshot") || name.hasSuffix("__take_screenshot")
    }

    static func imageName(name: String, input: [String: Any]) -> String? {
        name == "Read" ? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } : nil
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // Codable: the tuple-backed property is derived, so only stored state is encoded.
    private enum CodingKeys: String, CodingKey {
        case sessionId, events, branch, cwd, lastAt, customTitle, aiTitle, pending, narrating, turn
        case lastScreenshotId, lastScreenshotTurn, seq
    }
}

/// Byte-level checks on raw transcript lines, so most lines are never decoded.
enum Bytes {
    static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        index(of: needle, in: data) != nil
    }

    static func index(of needle: [UInt8], in data: Data) -> Int? {
        data.withUnsafeBytes { hay -> Int? in
            guard hay.count > 0, let base = hay.baseAddress else { return nil }
            return needle.withUnsafeBytes { n -> Int? in
                guard let found = memmem(base, hay.count, n.baseAddress!, n.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }

    /// The text right after `key` (e.g. ending with an opening quote), up to the first of `until`.
    static func value(after key: [UInt8], in data: Data, until: [UInt8] = [UInt8(ascii: "\"")]) -> String? {
        guard let i = index(of: key, in: data) else { return nil }
        let start = data.startIndex + i + key.count
        guard let end = data[start...].firstIndex(where: { until.contains($0) }) else { return nil }
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}

/// Small regex helpers: capture groups as optional strings (nil when a group didn't take part).
enum Rx {
    static func all(_ pattern: String, in s: String) -> [[String?]] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    static func first(_ pattern: String, in s: String) -> [String?]? { all(pattern, in: s).first }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
}
