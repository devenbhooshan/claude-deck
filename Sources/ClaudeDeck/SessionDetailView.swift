import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Parses a transcript on a background queue and publishes snapshots to the UI.
@MainActor
@Observable
final class TranscriptModel {
    private(set) var blocks: [TranscriptBlock] = []
    private(set) var results: [String: ToolResult] = [:]
    private(set) var pendingTool: (name: String, summary: String)?
    private(set) var queued: [String] = []
    private(set) var loaded = false
    /// Messages sent from Deck that haven't shown up in the transcript yet.
    private(set) var outgoing: [OutgoingMessage] = []


    private let queue = DispatchQueue(label: "transcript")
    private var parser: TranscriptParser?
    private var timer: Timer?
    private var watcher: FileWatcher?

    /// There's history before what's loaded (long sessions load their latest part first).
    private(set) var hasEarlier = false
    private var loadingEarlier = false

    /// Showing just the part of the transcript around a message (opened from search).
    private(set) var isWindow = false
    /// That message's text, to point it out.
    private(set) var focusText: String?

    func start(url: URL?, focus: FocusTarget? = nil) {
        guard let url else { loaded = true; return }
        let parser = TranscriptParser(url: url)
        self.parser = parser
        if let focus, let offset = focus.offset {
            // A fixed stretch of the file: it doesn't follow new lines (Back to Latest does).
            isWindow = true
            focusText = focus.text
            queue.async { [weak self] in
                parser.loadWindow(around: offset)
                let snapshot = (TranscriptBlock.group(parser.items), parser.results)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.blocks = snapshot.0
                    self.results = snapshot.1
                    self.loaded = true
                }
            }
            return
        }
        poll(force: true)
        // React to appends immediately; the timer is a fallback (e.g. the file was replaced).
        watcher = FileWatcher(url: url, events: [.extend, .write]) { [weak self] in
            MainActor.assumeIsolated { self?.poll(force: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(force: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher = nil
    }

    func markdown(title: String) -> String { TranscriptExport.markdown(title: title, blocks: blocks) }

    /// True from the moment you send until Claude reports it's working on it (or 15s pass).
    /// Kept separately from `outgoing`, which clears as soon as the message lands in the transcript,
    /// a moment before Claude Code marks the session busy; that gap made the working row flicker.
    private(set) var awaitingPickup = false
    /// When the current turn started: your send, else when Claude started. One timer for the whole turn.
    private(set) var turnStart: Date?

    /// `whileBusy`: Claude is already working, so the message just queues; the current turn goes on.
    func addOutgoing(text: String, images: [NSImage], whileBusy: Bool = false) -> UUID {
        let o = OutgoingMessage(text: text, images: images)
        outgoing.append(o)
        if whileBusy { return o.id }
        awaitingPickup = true
        if turnStart == nil { turnStart = o.sentAt }
        let sentAt = o.sentAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            // Never picked up (e.g. the send failed silently): stop showing activity.
            if self?.awaitingPickup == true, self?.turnStart == sentAt { self?.awaitingPickup = false }
        }
        return o.id
    }

    /// Follows the session's status: working → picked up; idle or waiting → the turn is over.
    func statusChanged(_ status: SessionStatus) {
        switch status {
        case .busy: awaitingPickup = false
        case .background, .idle, .waiting, .ended: if !awaitingPickup { turnStart = nil }
        }
    }

    func markDelivered(_ id: UUID) {
        if let i = outgoing.firstIndex(where: { $0.id == id }) { outgoing[i].delivered = true }
    }

    func removeOutgoing(_ id: UUID) {
        awaitingPickup = false
        turnStart = nil
        outgoing.removeAll { $0.id == id }
    }

    private func reconcileOutgoing() {
        outgoing = TranscriptExport.reconcile(outgoing, queued: queued, blocks: blocks)
    }

    /// Loads the history before what's shown (scrolled to the top).
    func loadEarlier() {
        guard let parser, hasEarlier, !loadingEarlier, !isWindow else { return }
        loadingEarlier = true
        queue.async { [weak self] in
            parser.loadEarlier()
            let snapshot = (TranscriptBlock.group(parser.items), parser.results, parser.hasEarlier)
            DispatchQueue.main.async {
                guard let self else { return }
                self.blocks = snapshot.0
                self.results = snapshot.1
                self.hasEarlier = snapshot.2
                self.loadingEarlier = false
            }
        }
    }

    private func poll(force: Bool) {
        guard let parser else { return }
        queue.async { [weak self] in
            let changed = parser.refresh()
            guard changed || force else { return }
            let snapshot = (TranscriptBlock.group(parser.items), parser.results, parser.pendingTool, parser.queued, parser.hasEarlier)
            DispatchQueue.main.async {
                guard let self else { return }
                self.blocks = snapshot.0
                self.results = snapshot.1
                self.pendingTool = snapshot.2
                self.queued = snapshot.3
                self.hasEarlier = snapshot.4
                self.loaded = true
                self.reconcileOutgoing()
            }
        }
    }
}

struct SessionDetailView: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    @State private var model = TranscriptModel()
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SessionWorkBar(session: session)
            if store.detailTab == .activity {
                ActivityPane(session: session)
            } else {
                if model.isWindow { EarlierPartBar { store.focus = nil } }
                conversation
            }
        }
        // Opened from search at a moment, or back to the latest part.
        .onChange(of: store.focus) { _, focus in
            guard focus == nil ? model.isWindow : focus?.sessionId == session.sessionId else { return }
            model.stop()
            model = TranscriptModel()
            model.start(url: session.transcriptURL, focus: focus)
        }
        .navigationTitle(session.displayTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear {
            model.start(url: session.transcriptURL, focus: store.focus?.sessionId == session.sessionId ? store.focus : nil)
            if session.isLive { Task { await Ghostty.prewarm(session) } }
        }
        .onDisappear { model.stop() }
        .alert("Couldn't reach the terminal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            TranscriptView(model: model, cwd: session.cwd, status: session.status, statusSince: session.statusSince,
                           onStop: session.isLive ? { store.interrupt(session) } : nil,
                           background: session.background,
                           onStopTask: session.isLive ? { store.stopTask($0, in: session) } : nil)
                .overlay(alignment: .bottom) {
                    if session.status == .waiting && !store.isAnswered(session) {
                        PendingCard(session: session,
                                    tool: session.pendingTool.map { ($0.name, $0.summary) },
                                    diff: session.pendingTool?.diff,
                                    perform: act, respond: { store.respond(session, key: $0) })
                            .padding(.horizontal, 20).padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            if session.isLive {
                Composer(session: session, model: model, attachments: $attachments, onError: { error = $0 })
            } else {
                EndedBar { act { try await Ghostty.resume(session) } }
            }
        }
        .animation(.snappy, value: session.status)
        .onChange(of: session.status) { model.statusChanged(session.status) }
        .background(Theme.surface)
        .overlay {
            if dropTargeted && session.isLive {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.06))
                    .overlay(Label("Drop images or files to attach", systemImage: "paperclip")
                        .font(.title3.weight(.medium)).foregroundStyle(Theme.accent))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            guard session.isLive else { return false }
            loadDropped(providers)
            return true
        }
    }

    private var subtitle: String {
        let status = store.restarting?.session.id == session.id ? "Restarting…"
            : store.ending.contains(session.sessionId) ? "Ending…"
            : session.status == .waiting ? "Waiting for \(session.waitingFor ?? "you")" : session.status.label
        let remote = session.isLive && store.isRemote(session) ? " · Remote Control" : ""
        return "\(status)\(remote) · \(Theme.shortPath(session.cwd))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.isLive {
                RemoteControlToggle(session: session)
            }
            if !session.isLive {
                Button {
                    act { try await Ghostty.resume(session) }
                } label: {
                    Label("Resume in Ghostty", systemImage: "play.fill")
                }
                .help("Open a Ghostty window running claude --resume")
            }
            Menu {
                Button("Rename…") { store.renameTarget = session }
                if session.isLive {
                    Button("Restart Session") { store.restart(session) }
                        .disabled(session.status != .idle || store.restarting != nil)
                        .help("Quit and resume Claude here so new skills, MCP servers and settings load")
                    Button("End Session") { store.requestEnd(session) }
                        .disabled(store.ending.contains(session.sessionId))
                        .help("Quit Claude and close its terminal (you can resume it later)")
                }
                Divider()
                Button("Copy Transcript") { copy(model.markdown(title: session.displayTitle)) }
                Button("Copy Session ID") { copy(session.sessionId) }
                Button("Copy Resume Command") {
                    copy("cd \(Safety.shellQuote(session.cwd)) && claude --resume \(Safety.shellQuote(session.sessionId))")
                }
                Divider()
                Button("Show Project in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
                }
                if let url = session.transcriptURL {
                    Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if let a = AttachmentStore.from(fileURL: url) { attachments.append(a) }
                    }
                }
            } else {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        if let img = NSImage(data: data), let a = AttachmentStore.from(image: img) { attachments.append(a) }
                    }
                }
            }
        }
    }
}

/// Floating card shown while Claude is blocked on you.
private struct PendingCard: View {
    let session: Session
    let tool: (name: String, summary: String)?
    /// For file edits: what will change.
    var diff: [DiffLine]? = nil
    let perform: (@escaping () async throws -> Void) -> Void
    let respond: (String) -> Void

    private var isPermission: Bool { Theme.isPermission(session) }

    private func size(of text: String) -> String {
        let lines = text.components(separatedBy: "\n").count
        return lines > 1 ? "\(lines) lines · \(text.count) chars" : "\(text.count) chars"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusIcon(status: .waiting, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isPermission ? "Claude wants to run a tool" : "Claude is waiting for you")
                        .font(.headline)
                    Text((session.waitingFor ?? "input").capitalizedFirst)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                OpenTerminalButton(session: session)
                    .buttonStyle(.deck(.link))
            }

            if isPermission, let tool {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ToolStyle.symbol(tool.name))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ToolStyle.displayName(tool.name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            // Size up front, so nothing long can hide below the fold.
                            if let diff {
                                let stats = LineDiff.stats(diff)
                                Text("+\(stats.added)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.success)
                                Text("−\(stats.removed)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.danger)
                            } else {
                                Text(size(of: tool.summary)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let diff {
                            Text(Theme.shortPath(tool.summary))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            DiffView(lines: diff).frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                        } else {
                            ScrollView {
                                Text(tool.summary)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
            } else if isPermission {
                Label("Deck can't see what this prompt is asking. Check it in the terminal, or set up approval details from the sidebar.",
                      systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ApprovalButtons(session: session, size: .large)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.waiting.opacity(0.45), lineWidth: 1)
        }
        .frame(maxWidth: 760)
    }

}

private struct EndedBar: View {
    let resume: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "moon.zzz").foregroundStyle(.secondary)
            Text("This session has ended.").foregroundStyle(.secondary)
            Spacer()
            Button("Resume in Ghostty", action: resume).buttonStyle(.deck(.primary))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A line diff: removed lines on red, added on green, with +/− gutters.
struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(mark(line.kind)).foregroundStyle(.secondary).frame(width: 10)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .context ? .secondary : line.kind == .gap ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(fill(line.kind))
                }
            }
            .textSelection(.enabled)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private func mark(_ k: DiffLine.Kind) -> String {
        switch k { case .added: "+"; case .removed: "−"; default: " " }
    }

    private func fill(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: Theme.success.opacity(0.16)
        case .removed: Theme.danger.opacity(0.13)
        default: .clear
        }
    }
}

/// Above a transcript opened at an older message: says so, and goes back to the live end.
private struct EarlierPartBar: View {
    let backToLatest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
            Text("Showing an earlier part of this session").font(.callout)
            Spacer()
            Button("Back to Latest", action: backToLatest)
                .buttonStyle(.deck(.secondary, size: .small))
                .help("Show the end of the conversation, live")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.accent.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Remote Control as one switch: on, you can drive the session from the Claude app or claude.ai.
struct RemoteControlToggle: View {
    @Environment(SessionStore.self) private var store
    let session: Session

    var body: some View {
        let on = store.isRemote(session)
        // A toolbar hides a toggle's own label, so the name sits beside the switch.
        HStack(spacing: 6) {
            Label("Remote Control", systemImage: "iphone.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(on ? Theme.accent : .secondary)
            Toggle("Remote Control", isOn: Binding(get: { on }, set: { store.setRemote(session, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.setRemote(session, on: !on) }
        .pointingHand()
        .disabled(store.remoteSwitching[session.sessionId] != nil)
        .help(on ? "Remote Control is on: drive this session from the Claude app or claude.ai. Turn off to disconnect."
                 : "Turn on to drive this session from the Claude app on your phone or claude.ai. It keeps running on this Mac.")
        .contextMenu {
            if let url = session.remoteURL {
                Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
                Button("Copy Link") { Clipboard.copy(url.absoluteString) }
            }
        }
    }
}
