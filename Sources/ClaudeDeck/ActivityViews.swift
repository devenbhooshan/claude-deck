import AppKit
import SwiftUI

/// Which half of a session the detail shows.
enum DetailTab: String { case conversation, activity }

extension ActivityEvent.Kind {
    var symbol: String {
        switch self {
        case .openedPR: "arrow.triangle.pull"
        case .mergedPR: "arrow.triangle.merge"
        case .reviewedPR: "checkmark.bubble"
        case .commentedPR, .commentedTicket: "text.bubble"
        case .viewedPR: "eye"
        case .linkedPR: "link"
        case .createdTicket: "plus.square"
        case .updatedTicket: "square.and.pencil"
        case .viewedTicket, .mentionedTicket: "ticket"
        case .screenshot: "photo"
        case .pushed: "arrow.up.circle"
        case .createdBranch: "arrow.branch"
        }
    }

    var tint: Color {
        switch self {
        case .openedPR: Theme.success
        case .mergedPR: .purple
        case .reviewedPR: Theme.busy
        case .createdTicket, .updatedTicket, .viewedTicket, .mentionedTicket, .commentedTicket: Theme.waiting
        case .screenshot: Theme.accent
        case .pushed: Theme.busy
        case .createdBranch: Theme.success
        case .commentedPR, .viewedPR, .linkedPR: .secondary
        }
    }
}

extension PRInfo.State {
    var label: String {
        switch self {
        case .open: "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        case .draft: "Draft"
        }
    }

    var tint: Color {
        switch self {
        case .open: Theme.success
        case .merged: .purple
        case .closed: Theme.danger
        case .draft: .secondary
        }
    }
}

/// A small capsule saying where a PR stands (Open, Merged, …).
struct PRStateBadge: View {
    let state: PRInfo.State

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(state.tint.opacity(0.14)))
    }
}

// MARK: - Session header

/// Above a session: what it's working on (ticket, PR with its status), and the
/// Conversation / Activity switch.
struct SessionWorkBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(ActivityStore.self) private var activity
    let session: Session

    var body: some View {
        @Bindable var store = store
        let work = activity.current(for: session.sessionId)
        let count = activity.events(for: session.sessionId).count
        HStack(spacing: 8) {
            if let work {
                Text("Working on")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if let ticket = work.ticket {
                    WorkChip(symbol: "ticket", tint: Theme.waiting, ref: ticket,
                             title: work.ticketTitle ?? ticketTitle(ticket), url: ticketURL(ticket), state: nil)
                }
                if let pr = work.pr {
                    WorkChip(symbol: "arrow.triangle.pull", tint: Theme.success, ref: pr.ref ?? "",
                             title: activity.title(for: pr), url: activity.url(for: pr), state: activity.pr(for: pr)?.state)
                        .onAppear { activity.appeared([pr]) }
                }
            }
            Spacer(minLength: 8)
            DeckTabs(items: [
                .init(value: DetailTab.conversation, title: "Conversation", help: "The conversation (⌥⌘A)"),
                .init(value: DetailTab.activity, title: "Activity", count: count,
                      help: "What this session did with PRs, tickets and screenshots (⌥⌘A)"),
            ], selection: $store.detailTab)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func ticketTitle(_ ticket: String) -> String? {
        activity.events(for: session.sessionId).first { $0.ticket == ticket }.flatMap { activity.title(for: $0) }
    }

    private func ticketURL(_ ticket: String) -> URL? {
        (activity.all.first { $0.ticket == ticket && $0.url != nil }?.url ?? ActivityEvent.linearURL(for: ticket, in: activity.all))
            .flatMap(URL.init(string:))
    }
}

private struct WorkChip: View {
    let symbol: String
    let tint: Color
    let ref: String
    let title: String?
    let url: URL?
    let state: PRInfo.State?
    @State private var hovering = false

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(ref).font(.caption.monospaced().weight(.semibold))
                if let title {
                    Text(ActivityEvent.trimmed(title, ref: ref)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                if let state { PRStateBadge(state: state) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(hovering && url != nil ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.deckPlain)
        // Without a link it's just a label: full strength, no hand.
        .allowsHitTesting(url != nil)
        .onHover { hovering = $0 }
        .help(url.map { "Open \($0.absoluteString)" } ?? (title ?? ref))
    }
}

// MARK: - Activity list

/// Events grouped by day, newest first.
struct ActivityList: View {
    @Environment(ActivityStore.self) private var activity
    let events: [ActivityEvent]
    /// History shows which session each event came from.
    var showsSession = false
    var sessionTitle: (String) -> String = { _ in "" }
    var openSession: ((ActivityEvent) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
            ForEach(ActivityIndex.byDay(events), id: \.day) { group in
                Section {
                    ForEach(group.events) { e in
                        ActivityRow(event: e, showsSession: showsSession, sessionTitle: sessionTitle(e.sessionId),
                                    openSession: openSession.map { open in { open(e) } })
                            .onAppear { activity.appeared([e]) }
                    }
                } header: {
                    Text(ActivityIndex.dayLabel(group.day))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }
}

struct ActivityRow: View {
    @Environment(ActivityStore.self) private var activity
    let event: ActivityEvent
    var showsSession = false
    var sessionTitle = ""
    var openSession: (() -> Void)? = nil
    @State private var hovering = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let title = activity.title(for: event)
        let summary = activity.summaries[event.id]
        let note = summary ?? event.quote
        let url = activity.url(for: event)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.kind.tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(event.kind.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.label).font(.callout.weight(.semibold))
                    if let ref = event.ref {
                        Text(ref).font(.callout.monospaced()).foregroundStyle(Theme.accent)
                    }
                    if let state = activity.pr(for: event)?.state { PRStateBadge(state: state) }
                    Spacer(minLength: 6)
                    if let at = event.at {
                        Text(Self.time.string(from: at)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                if let title {
                    Text(ActivityEvent.trimmed(title, ref: event.isTicket ? event.ref : nil)).font(.callout).lineLimit(1)
                }
                if event.kind == .screenshot || event.isCode, let detail = event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if summary != nil {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(Theme.accent)
                                .help("Summary by Claude Haiku")
                        }
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if showsSession {
                    Text([sessionTitle, activity.repo(for: event)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Color.primary.opacity(hovering && primary(url) != nil ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { primary(url)?() }
        .pointingHand(primary(url) != nil)
        .help(openSession != nil ? "Open this session" : url.map { "Open \($0.absoluteString)" } ?? "")
        .contextMenu {
            if let openSession { Button("Open Session", action: openSession) }
            if let url {
                Button("Open \(event.isTicket ? "Ticket" : "PR")") { NSWorkspace.shared.open(url) }
                Button("Copy Link") { Clipboard.copy(url.absoluteString) }
            }
            if let note { Button("Copy Summary") { Clipboard.copy(note) } }
        }
    }

    /// History opens the session; a session's own list opens the PR or ticket.
    private func primary(_ url: URL?) -> (() -> Void)? {
        if let openSession { return openSession }
        return url.map { u in { NSWorkspace.shared.open(u) } }
    }
}

// MARK: - A session's Activity tab

struct ActivityPane: View {
    @Environment(ActivityStore.self) private var activity
    let session: Session

    var body: some View {
        let events = activity.events(for: session.sessionId)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if events.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: activity.loaded ? "tray" : "hourglass")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text(activity.loaded ? "Nothing yet" : "Reading this session…").font(.headline)
                        Text("PRs and tickets this session opens, reviews, merges or updates, and screenshots it looks at, show up here.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    RecapCard(sessionId: session.sessionId, title: session.displayTitle)
                    ActivityList(events: events)
                }
            }
            .frame(maxWidth: 816)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A 2–3 sentence recap of the session, written on request.
struct RecapCard: View {
    @Environment(ActivityStore.self) private var activity
    let sessionId: String
    let title: String

    var body: some View {
        let recap = activity.recaps[sessionId]
        let working = activity.recapping.contains(sessionId)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Recap").font(.callout.weight(.semibold))
                if let recap {
                    Text("· \(Theme.ago(recap.at)) ago").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button(recap == nil ? "Summarize Session" : "Refresh") { activity.recap(sessionId, title: title) }
                        .buttonStyle(.deck(.secondary, size: .small))
                        .help("Claude Haiku writes a short recap from this session's activity")
                }
            }
            if let recap {
                Text(recap.text).font(.callout).textSelection(.enabled)
            } else if !working {
                Text("A short recap of what this session shipped, reviewed and has in progress.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Theme.accent.opacity(0.15)))
    }
}

// MARK: - History window

struct HistoryView: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(SessionStore.self) private var store
    @State private var query = ""
    @State private var filter: ActivityIndex.Filter = .all
    @State private var showDigest = false

    private func title(_ id: String) -> String {
        store.session(id)?.displayTitle ?? activity.sessionTitle(id) ?? activity.sessionFolder(id).map { ($0 as NSString).lastPathComponent } ?? "Session"
    }

    var body: some View {
        @Bindable var activity = activity
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let results = ActivityIndex.browse(activity.all, filter: filter)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if searching {
                    Text("Search your sessions").font(.callout.weight(.semibold))
                } else {
                    DeckTabs(items: ActivityIndex.Filter.allCases.map { f in
                        .init(value: f, title: f.rawValue,
                              count: f == .all ? nil : ActivityIndex.browse(activity.all, filter: f).count)
                    }, selection: $filter)
                }
                Spacer()
                if activity.indexing || activity.summarizing {
                    ProgressView().controlSize(.small)
                        .help(activity.indexing ? "Reading transcripts…" : "Writing summaries…")
                }
                Toggle("AI summaries", isOn: $activity.aiSummaries)
                    .toggleStyle(.switch).controlSize(.small)
                    .pointingHand()
                    .help("One-line summaries by Claude Haiku, using your claude login (at most \(ActivityStore.dailyCallLimit) small calls a day, only while you're idle)")
                Button {
                    showDigest = true
                    makeDigest()
                } label: {
                    Label("Today's Digest", systemImage: "text.badge.star")
                }
                .buttonStyle(.deck(.secondary, size: .small))
                .disabled(todays.isEmpty)
                .help("A short standup note of what your sessions did today")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if !activity.loaded {
                ProgressView("Reading your sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searching {
                ScrollView {
                    SearchResultsView(query: query, title: title)
                        .frame(maxWidth: 860)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            } else if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No activity yet" : "No matches").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ActivityList(events: results, showsSession: true, sessionTitle: title, openSession: open)
                        .frame(maxWidth: 860)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .searchable(text: $query, placement: .toolbar, prompt: "Search, or ask: when did I start…")
        .onSubmit(of: .search) { activity.ask(query, title: title) }
        .navigationTitle("Activity History")
        .navigationSubtitle(searching ? "Search" : "\(results.count) event\(results.count == 1 ? "" : "s")")
        .sheet(isPresented: $showDigest) { DigestSheet(regenerate: makeDigest) }
        .alert("Couldn't finish that", isPresented: Binding(get: { activity.lastError != nil }, set: { if !$0 { activity.lastError = nil } })) {
            Button("OK") { activity.lastError = nil }
        } message: {
            Text(activity.lastError ?? "")
        }
    }

    private var todays: [ActivityEvent] {
        activity.all.filter { $0.at.map { Calendar.current.isDateInToday($0) } ?? false }
    }

    private func makeDigest() {
        let f = DateFormatter()
        f.dateStyle = .full
        activity.makeDigest(day: "today, \(f.string(from: Date()))", events: todays, sessionTitle: title)
    }

    private func open(_ e: ActivityEvent) {
        if store.session(e.sessionId) != nil {
            store.selectedId = e.sessionId
            store.detailTab = .activity
            store.bringToFront()
        } else if let url = activity.url(for: e) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct DigestSheet: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(\.dismiss) private var dismiss
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Today's Digest").font(.title3.weight(.semibold))
                Spacer()
                if activity.digestLoading { ProgressView().controlSize(.small) }
            }
            if let digest = activity.digest {
                ScrollView {
                    Text(digest.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 360)
            } else {
                Text(activity.digestLoading ? "Claude Haiku is writing it…" : "Nothing to summarize today.")
                    .foregroundStyle(.secondary).frame(minHeight: 120)
            }
            HStack {
                Button("Regenerate", action: regenerate)
                    .buttonStyle(.deck(.secondary))
                    .disabled(activity.digestLoading)
                Spacer()
                Button("Copy") { if let d = activity.digest { Clipboard.copy(d.text) } }
                    .buttonStyle(.deck(.secondary))
                    .disabled(activity.digest == nil)
                Button("Done") { dismiss() }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Search

/// Results for what's typed in History's search: matches as you type, and an answer from
/// Claude Haiku when you press Return on a question.
struct SearchResultsView: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(SessionStore.self) private var store
    let query: String
    let title: (String) -> String

    var body: some View {
        let quick = activity.quickSearch(query)
        let answer = activity.answer?.question == query.trimmingCharacters(in: .whitespacesAndNewlines) ? activity.answer : nil
        let sessions = answer?.sessions ?? quick.sessions
        let order = answer?.order ?? quick.order
        let highlight = answer.map { ([query] + $0.terms).joined(separator: " ") } ?? query
        VStack(alignment: .leading, spacing: 14) {
            AskBar(query: query, asking: activity.asking && answer != nil) { activity.ask(query, title: title) }
            if let answer { AnswerCard(answer: answer, query: highlight, title: title, open: open) }
            if sessions.isEmpty {
                Text(activity.searchIndex == nil ? "Reading your sessions…" : "No matches yet. Press ↩ to ask Claude, which also tries other spellings and related words.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Text(order == .first ? "Sessions, by when it first came up" : order == .latest ? "Sessions, most recent first" : "Sessions")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sessions, id: \.sessionId) { s in
                    SessionResultCard(hit: s, title: title(s.sessionId), query: highlight, open: open)
                }
            }
        }
    }

    private func open(_ sessionId: String, _ doc: SearchDoc?) {
        var text = doc?.text
        if case .event = doc?.kind { text = activity.all.first { $0.id == doc?.id }?.quote }
        store.open(FocusTarget(sessionId: sessionId, offset: doc?.offset, text: text), stub: activity.sessionStub(sessionId))
    }
}

private struct AskBar: View {
    let query: String
    let asking: Bool
    let ask: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: ask) {
            HStack(spacing: 8) {
                if asking {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading your sessions…").font(.callout)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("Ask Claude: ").font(.callout.weight(.semibold)) + Text("“\(query)”").font(.callout)
                }
                Spacer()
                Text("↩").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.accent.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .disabled(asking)
        .onHover { hovering = $0 }
        .help("Claude Haiku turns your question into a search (fixing typos, adding related words) and answers it")
    }
}

private struct AnswerCard: View {
    let answer: ActivityStore.SearchAnswer
    let query: String
    let title: (String) -> String
    let open: (String, SearchDoc?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = answer.text {
                Text(text).font(.body).textSelection(.enabled)
            } else if answer.failed {
                Text("Couldn't get an answer from Claude right now; here's what the search found.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(answer.picks, id: \.hit.doc.id) { pick in
                MomentRow(doc: pick.hit.doc, session: title(pick.hit.doc.sessionId), why: pick.why, query: query) {
                    open(pick.hit.doc.sessionId, pick.hit.doc)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Theme.accent.opacity(0.15)))
    }
}

private struct SessionResultCard: View {
    let hit: SessionHit
    let title: String
    let query: String
    let open: (String, SearchDoc?) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open(hit.sessionId, nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Theme.accent)
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let first = hit.first {
                        Text(Self.span(first, hit.last)).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.deckPlain)
            .onHover { hovering = $0 }
            .help("Open this session")
            ForEach(hit.hits, id: \.doc.id) { h in
                MomentRow(doc: h.doc, session: nil, why: nil, query: query) { open(hit.sessionId, h.doc) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private static func span(_ first: Date, _ last: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let a = f.string(from: first), b = last.map(f.string) ?? a
        return a == b ? a : "\(a) – \(b)"
    }
}

/// One matching moment: what you said or what the session did, when; opens the session there.
private struct MomentRow: View {
    let doc: SearchDoc
    let session: String?
    let why: String?
    let query: String
    let open: () -> Void
    @State private var hovering = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let session { Text(session).font(.caption.weight(.semibold)) }
                        Text(doc.at.map(Self.time.string) ?? "").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(Highlight.text(doc.text, query: query)).font(.callout).lineLimit(3)
                    if let why, !why.isEmpty {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .onHover { hovering = $0 }
        .help(doc.offset != nil ? "Open the session at this moment" : "Open this session")
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

/// Bold, accent-coloured words that match the search.
enum Highlight {
    static func text(_ text: String, query: String) -> AttributedString {
        var out = AttributedString(text)
        let wanted = Set(SearchIndex.tokens(query))
        guard !wanted.isEmpty else { return out }
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = SearchIndex.stem(ns.substring(with: m.range).lowercased())
            guard wanted.contains(where: { word == $0 || word.hasPrefix($0) }),
                  let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].font = .callout.weight(.semibold)
            out[ar].foregroundColor = Theme.accent
        }
        return out
    }
}

/// Opens the History window with the cursor in its search box (SwiftUI can only focus a
/// toolbar search field from macOS 15, so this finds the field and focuses it).
enum SearchFocus {
    @MainActor static func open(_ openWindow: () -> Void) {
        openWindow()
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.title == "Activity History" }) else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let field = window.toolbar?.items.lazy.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
                    ?? findSearchField(in: window.contentView?.superview)
                if let field, window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
            }
        }
    }

    private static func findSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let f = findSearchField(in: sub) { return f } }
        return nil
    }
}
