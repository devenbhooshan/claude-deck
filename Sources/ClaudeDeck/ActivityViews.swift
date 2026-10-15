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
        let task = activity.task(for: session.sessionId)
        let count = activity.events(for: session.sessionId).count
        HStack(spacing: 8) {
            if work != nil || task != nil {
                Text("Working on")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let task {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(task).font(.caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.1)))
                .help("Named by Claude Haiku from your latest messages")
            }
            if let work {
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
        // Name the task again whenever you send a new message here.
        .task(id: activity.lastAsk(session.sessionId)) { activity.nameTask(session.sessionId) }
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
                        .background(Theme.surface)
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
        .background(Theme.surface)
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

// MARK: - History & search panel

/// Shown over the main window (⇧⌘H): every PR, ticket, push and screenshot across sessions, with
/// filters and the daily digest. Searching is ⌘K. Esc or a click outside closes it.
struct HistoryPanel: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(SessionStore.self) private var store
    @State private var filter: ActivityIndex.Filter = .all
    @State private var showDigest = false

    private func title(_ id: String) -> String {
        store.session(id)?.displayTitle ?? activity.sessionTitle(id) ?? activity.sessionFolder(id).map { ($0 as NSString).lastPathComponent } ?? "Session"
    }

    var body: some View {
        @Bindable var activity = activity
        let results = ActivityIndex.browse(activity.all, filter: filter)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                Text("Activity").font(.title3.weight(.semibold))
                Text("\(results.count) events · search with ⌘K").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if activity.indexing || activity.summarizing {
                    ProgressView().controlSize(.small)
                        .help(activity.indexing ? "Reading transcripts…" : "Writing summaries…")
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.deckPlain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            Group {
                HStack(spacing: 12) {
                    DeckTabs(items: ActivityIndex.Filter.allCases.map { f in
                        .init(value: f, title: f.rawValue,
                              count: f == .all ? nil : ActivityIndex.browse(activity.all, filter: f).count)
                    }, selection: $filter)
                    Spacer()
                    Toggle("AI summaries", isOn: $activity.aiSummaries)
                        .toggleStyle(.switch).controlSize(.small)
                        .pointingHand()
                        .help("One-line summaries by Claude Haiku, using your claude login (at most \(ActivityStore.dailyCallLimit) small calls a day, only while you're not typing)")
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
            }
            Group {
                if !activity.loaded {
                    ProgressView("Reading your sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                        Text("No activity yet").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        ActivityList(events: results, showsSession: true, sessionTitle: title, openSession: open)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.surface)
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onExitCommand(perform: close)
        .sheet(isPresented: $showDigest) { DigestSheet(regenerate: makeDigest) }
        .alert("Couldn't finish that", isPresented: Binding(get: { activity.lastError != nil }, set: { if !$0 { activity.lastError = nil } })) {
            Button("OK") { activity.lastError = nil }
        } message: {
            Text(activity.lastError ?? "")
        }
    }

    private func close() { store.showHistory = false }

    private var todays: [ActivityEvent] {
        activity.all.filter { $0.at.map { Calendar.current.isDateInToday($0) } ?? false }
    }

    private func makeDigest() {
        let f = DateFormatter()
        f.dateStyle = .full
        activity.makeDigest(day: "today, \(f.string(from: Date()))", events: todays, sessionTitle: title)
    }

    private func open(_ e: ActivityEvent) {
        if store.session(e.sessionId) != nil || activity.sessionStub(e.sessionId) != nil {
            store.open(FocusTarget(sessionId: e.sessionId, offset: nil, text: nil), stub: activity.sessionStub(e.sessionId))
            store.detailTab = .activity
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
