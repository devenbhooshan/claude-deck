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

    func start(url: URL?) {
        guard let url else { loaded = true; return }
        let parser = TranscriptParser(url: url)
        self.parser = parser
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

    func addOutgoing(text: String, images: [NSImage]) -> UUID {
        let o = OutgoingMessage(text: text, images: images)
        outgoing.append(o)
        return o.id
    }

    func markDelivered(_ id: UUID) {
        if let i = outgoing.firstIndex(where: { $0.id == id }) { outgoing[i].delivered = true }
    }

    func removeOutgoing(_ id: UUID) {
        outgoing.removeAll { $0.id == id }
    }

    private func reconcileOutgoing() {
        outgoing = TranscriptExport.reconcile(outgoing, queued: queued, blocks: blocks)
    }

    private func poll(force: Bool) {
        guard let parser else { return }
        queue.async { [weak self] in
            let changed = parser.refresh()
            guard changed || force else { return }
            let snapshot = (TranscriptBlock.group(parser.items), parser.results, parser.pendingTool, parser.queued)
            DispatchQueue.main.async {
                guard let self else { return }
                self.blocks = snapshot.0
                self.results = snapshot.1
                self.pendingTool = snapshot.2
                self.queued = snapshot.3
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
            TranscriptView(model: model, cwd: session.cwd, status: session.status, statusSince: session.statusSince)
                .overlay(alignment: .bottom) {
                    if session.status == .waiting && !store.isAnswered(session) {
                        PendingCard(session: session,
                                    tool: session.pendingTool.map { ($0.name, $0.summary) } ?? model.pendingTool,
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
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTargeted && session.isLive {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.06))
                    .overlay(Label("Drop images to attach", systemImage: "photo.badge.plus")
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
        .navigationTitle(session.displayTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear {
            model.start(url: session.transcriptURL)
            if session.isLive { Task { await Ghostty.prewarm(session) } }
        }
        .onDisappear { model.stop() }
        .alert("Couldn't reach the terminal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var subtitle: String {
        let status = session.status == .waiting ? "Waiting for \(session.waitingFor ?? "you")" : session.status.label
        return "\(status) · \(Theme.shortPath(session.cwd))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.isLive {
                OpenTerminalButton(session: session)
                    .help("Jump to this session's Ghostty terminal (⇧⌘T)")
            } else {
                Button {
                    act { try await Ghostty.resume(session) }
                } label: {
                    Label("Resume in Ghostty", systemImage: "play.fill")
                }
                .help("Open a Ghostty window running claude --resume")
            }
            Menu {
                Button("Rename…") { store.renameTarget = session }
                Divider()
                Button("Copy Transcript") { copy(model.markdown(title: session.displayTitle)) }
                Button("Copy Session ID") { copy(session.sessionId) }
                Button("Copy Resume Command") { copy("cd \(session.cwd) && claude --resume \(session.sessionId)") }
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
    let perform: (@escaping () async throws -> Void) -> Void
    let respond: (String) -> Void

    private var isPermission: Bool { Theme.isPermission(session) }

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ToolStyle.displayName(tool.name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(tool.summary)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
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
