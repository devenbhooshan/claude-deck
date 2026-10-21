import AppKit
import SwiftUI

/// The conversation, rendered into one native text view so you can select and copy across
/// every message (⌘A, drag, ⌘C, right-click → Copy). SwiftUI can only select within a single
/// view, so a SwiftUI list of messages can't do that.
struct TranscriptView: View {
    let model: TranscriptModel
    let cwd: String
    let status: SessionStatus
    let statusSince: Date?
    /// Stops the current step (shown as a Stop button while Claude works).
    var onStop: (() -> Void)? = nil
    /// Commands Claude left running in the background, and how to stop one.
    var background: [BackgroundTask] = []
    var onStopTask: ((BackgroundTask) -> Void)? = nil

    /// The last tool call, if it has no result yet. Older unresolved calls were interrupted.
    private var openTool: ToolCall? {
        guard case .tools(let calls)? = model.blocks.last, let last = calls.last,
              model.results[last.id] == nil else { return nil }
        return last
    }

    /// A message you just sent that Claude hasn't picked up yet: show activity right away,
    /// and keep it on continuously until Claude reports it's working (no gap, no flicker).
    private var sending: Bool { status != .busy && status != .waiting && model.awaitingPickup }

    private var active: Bool { status == .busy || sending || showsTasks }

    /// Claude is at its prompt with something still running: the tasks take the pill.
    private var showsTasks: Bool {
        !sending && (status == .background || (status == .idle && !background.isEmpty))
    }

    var body: some View {
        TranscriptTextView(content: TranscriptContent(
            blocks: model.blocks, results: model.results, queued: model.queued, outgoing: model.outgoing,
            cwd: cwd, status: status,
            openToolId: status == .busy || status == .waiting ? openTool?.id : nil,
            loaded: model.loaded, focus: model.focusText))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The row's space is always reserved, so the transcript never jumps when it appears;
                // its contents fade in and out. Lined up with the reading column, under the last message.
                HStack(spacing: 8) {
                    if showsTasks {
                        BackgroundTasksPill(tasks: background, since: statusSince, onStop: onStopTask)
                    } else {
                        WorkingRow(tool: status == .busy ? openTool : nil, since: model.turnStart ?? statusSince,
                                   sending: sending)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                    if let onStop, !showsTasks {
                        // Present from the start (no second pop-in), usable once Claude is working.
                        Button(action: onStop) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.deck(.secondary, size: .small))
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(status != .busy)
                        .help("Stop Claude's current step (⌘.)")
                    }
                    Spacer()
                }
                .frame(height: 30)
                .frame(maxWidth: ColumnTextView.maxColumn)
                .padding(.horizontal, 28)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .animation(.easeInOut(duration: 0.2), value: active)
                .animation(.easeInOut(duration: 0.2), value: status)
            }
    }
}

// MARK: - AppKit text view

struct TranscriptTextView: NSViewRepresentable {
    let content: TranscriptContent
    @Environment(SessionStore.self) private var store

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: { NSWorkspace.shared.open($0) }, openFile: { [store] in store.viewing = ViewedFile(url: $0) })
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    /// Take exactly the space offered. Without this SwiftUI sizes the view to the text's width,
    /// which widened the whole session column past the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.content = content
        context.coordinator.render(force: false)
    }

    final class Coordinator: TranscriptTextController {}
}

/// Shown while Claude is busy. The transcript only gets complete messages, so this
/// fills the gap while Claude thinks or writes.
/// What Claude left running in the background, how long for, and a way to stop it. A server
/// (bin/dev, npm run dev…) is shown quietly: it's meant to keep running.
struct BackgroundTasksPill: View {
    let tasks: [BackgroundTask]
    /// When the session started running in the background, if the tasks themselves aren't known.
    let since: Date?
    let onStop: ((BackgroundTask) -> Void)?
    @State private var confirm: [BackgroundTask] = []
    @State private var pulse = false

    private var onlyServers: Bool { !tasks.isEmpty && tasks.allSatisfy(\.isServer) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if onlyServers {
                    Image(systemName: "server.rack")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.idle)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .scaleEffect(pulse ? 1.15 : 0.8)
                        .opacity(pulse ? 1 : 0.6)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                }
                label
                if let start = tasks.first?.started ?? since {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Format.elapsed(since: start, now: ctx.date))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .help(tasks.map(\.command).joined(separator: "\n"))
            if let onStop, !tasks.isEmpty {
                // One task: confirm it. Several: the dialog asks which (that choice is the confirmation).
                Button { confirm = tasks } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.deck(.secondary, size: .small))
                    .help(tasks.count == 1 ? "Stop \(tasks[0].command)" : "Stop a background task")
                    .confirmationDialog(confirm.count == 1 ? "Stop \(confirm[0].command)?" : "Stop which background task?",
                                        isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } })) {
                        if confirm.count == 1 {
                            Button("Stop", role: .destructive) { confirm.forEach(onStop); confirm = [] }
                        } else {
                            ForEach(confirm) { t in Button("Stop \(t.command)", role: .destructive) { onStop(t); confirm = [] } }
                            Button("Stop All \(confirm.count)", role: .destructive) { confirm.forEach(onStop); confirm = [] }
                        }
                        Button("Cancel", role: .cancel) { confirm = [] }
                    } message: {
                        Text("Ends the command and everything it started. Claude keeps running, and you can ask it to start it again.")
                    }
            }
        }
        .onAppear { pulse = true }
    }

    @ViewBuilder private var label: some View {
        if let first = tasks.first {
            HStack(spacing: 4) {
                Text(first.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(tasks.count > 1 ? "+ \(tasks.count - 1) more" : onlyServers ? "running" : "running in background")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Background task running").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct WorkingRow: View {
    let tool: ToolCall?
    let since: Date?
    /// A message is on its way and Claude hasn't picked it up yet.
    var sending = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .scaleEffect(pulse ? 1.15 : 0.8)
                .opacity(pulse ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(since, ctx.date))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { pulse = true }
    }

    private var label: String {
        if sending { return "Sending…" }
        guard let tool else { return "Thinking…" }
        return "Running \(ToolStyle.displayName(tool.name))…"
    }

    private func elapsed(_ start: Date, _ now: Date) -> String { Format.elapsed(since: start, now: now) }
}
