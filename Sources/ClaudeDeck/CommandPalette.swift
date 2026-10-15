import AppKit
import SwiftUI

/// ⌘K (and ⌘F): one place to jump to a session, search everything your sessions said and did, or
/// ask a question in plain words. ↑/↓ move through every row, ↩ opens, ⌘↩ asks Claude, Esc closes.
struct CommandPalette: View {
    @Environment(SessionStore.self) private var store
    @Environment(ActivityStore.self) private var activity
    @State private var query: String
    @State private var highlighted = 0

    init(query: String = "") { _query = State(initialValue: query) }
    @FocusState private var focused: Bool

    enum Row: Identifiable {
        case session(Session)
        case ask
        case moment(SearchDoc, why: String?)
        case event(ActivityEvent)

        var id: String {
            switch self {
            case .session(let s): "s:\(s.id)"
            case .ask: "ask"
            case .moment(let d, _): "m:\(d.id)"
            case .event(let e): "e:\(e.id)"
            }
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var answer: ActivityStore.SearchAnswer? { activity.answer?.question == trimmed ? activity.answer : nil }

    private var sessions: [Session] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return Array(store.ordered.prefix(8)) }
        return Array(store.ordered.filter { "\($0.displayTitle) \($0.projectName) \($0.cwd)".lowercased().contains(q) }.prefix(5))
    }

    /// Claude's picks first (with why), then the other matches, one list.
    private var moments: [(doc: SearchDoc, why: String?)] {
        guard !trimmed.isEmpty else { return [] }
        let picks = answer?.picks.map { ($0.hit.doc, Optional($0.why)) } ?? []
        let found = (answer?.sessions ?? activity.quickSearch(trimmed).sessions).flatMap(\.hits).map(\.doc)
        let rest = found.filter { d in !picks.contains { $0.0.id == d.id } }.map { ($0, String?.none) }
        return Array((picks + rest).prefix(12))
    }

    private var recent: [ActivityEvent] { trimmed.isEmpty ? Array(activity.all.prefix(6)) : [] }

    private var rows: [Row] {
        sessions.map(Row.session) + (trimmed.isEmpty ? [] : [.ask]) + moments.map { .moment($0.doc, why: $0.why) } + recent.map(Row.event)
    }

    private func title(_ id: String) -> String {
        store.session(id)?.displayTitle ?? activity.sessionTitle(id) ?? activity.sessionFolder(id).map { ($0 as NSString).lastPathComponent } ?? "Session"
    }

    var body: some View {
        let rows = rows
        let highlight = answer.map { ([trimmed] + $0.terms).joined(separator: " ") } ?? trimmed
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session, search, or ask…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.command) { ask() } else { activate(rows) }
                        return .handled
                    }
                if activity.asking { ProgressView().controlSize(.small).help("Claude is reading your sessions…") }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if let answer, answer.text != nil || answer.failed {
                            AnswerBlock(answer: answer)
                        }
                        section("Sessions", visible: !sessions.isEmpty)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if case .moment = row, i == sessions.count + 1 {
                                header(answer?.picks.isEmpty == false ? "Claude's picks and other matches" : "In your sessions")
                            }
                            if case .event = row, i == sessions.count {
                                header("Recent activity")
                            }
                            rowView(row, highlight: highlight)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                    .fill(i == highlighted ? Theme.accent.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { highlighted = i; activate(rows) }
                                .onHover { if $0 { highlighted = i } }
                                .pointingHand()
                                .id(row.id)
                        }
                        if rows.isEmpty {
                            Text("No sessions yet").foregroundStyle(.tertiary).padding(20)
                        } else if !trimmed.isEmpty && moments.isEmpty && !activity.asking && answer == nil {
                            Text("Nothing found by keyword. Ask Claude (⌘↩) to try other spellings and related words.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 520)
                .onChange(of: highlighted) { if rows.indices.contains(highlighted) { proxy.scrollTo(rows[highlighted].id) } }
            }
            Divider()
            Text("↑↓ move · ↩ open · ⌘↩ ask Claude · esc close")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .frame(width: 680)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: Row, highlight: String) -> some View {
        switch row {
        case .session(let s):
            HStack(spacing: 10) {
                StatusIcon(status: s.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayTitle).lineLimit(1)
                    Text(s.status == .waiting ? "\(s.projectName) · Needs you" : s.projectName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let n = store.live.firstIndex(where: { $0.id == s.id }), n < 9 {
                    Text("⌘\(n + 1)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        case .ask:
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 22)
                (Text("Ask Claude: ").fontWeight(.semibold) + Text("“\(trimmed)”")).lineLimit(1)
                Spacer()
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
            }
        case .moment(let doc, let why):
            MomentLine(doc: doc, session: title(doc.sessionId), why: why, highlight: highlight)
        case .event(let e):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: e.kind.symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(e.kind.tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(e.kind.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(e.label).fontWeight(.medium)
                        if let ref = e.ref { Text(ref).foregroundStyle(Theme.accent).lineLimit(1) }
                    }
                    Text([title(e.sessionId), activity.title(for: e)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let at = e.at { Text(Theme.ago(at)).font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    private func section(_ title: String, visible: Bool) -> some View {
        Group { if visible { header(title) } }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    // MARK: - Actions

    private func move(_ d: Int) {
        let n = rows.count
        guard n > 0 else { return }
        highlighted = (highlighted + d + n) % n
    }

    private func ask() {
        guard !trimmed.isEmpty else { return }
        activity.ask(trimmed, title: title)
    }

    private func activate(_ rows: [Row]) {
        guard rows.indices.contains(highlighted) else { return }
        switch rows[highlighted] {
        case .session(let s):
            store.selectedId = s.id
            close()
        case .ask:
            ask()
        case .moment(let doc, _):
            var text: String? = doc.text
            if case .event = doc.kind { text = activity.all.first { $0.id == doc.id }?.quote }
            store.open(FocusTarget(sessionId: doc.sessionId, offset: doc.offset, text: text), stub: activity.sessionStub(doc.sessionId))
            close()
        case .event(let e):
            store.open(FocusTarget(sessionId: e.sessionId, offset: e.offset, text: e.quote), stub: activity.sessionStub(e.sessionId))
            close()
        }
    }

    private func close() { store.showSwitcher = false }
}

/// Claude's answer to the question, at the top of the palette.
private struct AnswerBlock: View {
    let answer: ActivityStore.SearchAnswer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text(answer.text ?? "Couldn't get an answer from Claude right now; here's what the search found.")
                .font(.body).foregroundStyle(answer.text == nil ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .padding(.bottom, 4)
    }
}

/// A matching moment: which session, when, and the words, with the matches highlighted.
private struct MomentLine: View {
    let doc: SearchDoc
    let session: String
    let why: String?
    let highlight: String

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(doc.at.map(Self.time.string) ?? "").font(.caption).foregroundStyle(.tertiary)
                }
                Text(Highlight.text(doc.text, query: highlight)).font(.callout).lineLimit(2)
                if let why, !why.isEmpty {
                    Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch doc.kind {
        case .message: "person.fill"
        case .event(let k): k.symbol
        case .session: "text.bubble"
        }
    }

    private var tint: Color {
        if case .event(let k) = doc.kind { return k.tint }
        return Theme.accent
    }
}
