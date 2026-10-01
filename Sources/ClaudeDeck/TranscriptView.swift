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

    /// The last tool call, if it has no result yet. Older unresolved calls were interrupted.
    private var openTool: ToolCall? {
        guard case .tools(let calls)? = model.blocks.last, let last = calls.last,
              model.results[last.id] == nil else { return nil }
        return last
    }

    var body: some View {
        TranscriptTextView(content: TranscriptContent(
            blocks: model.blocks, results: model.results, queued: model.queued, outgoing: model.outgoing,
            cwd: cwd, status: status,
            openToolId: status == .busy || status == .waiting ? openTool?.id : nil,
            loaded: model.loaded))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if status == .busy {
                    // Lined up with the reading column, under the last message (never covering it).
                    HStack(spacing: 8) {
                        WorkingRow(tool: openTool, since: statusSince)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        if let onStop {
                            Button(action: onStop) {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.deck(.secondary, size: .small))
                            .keyboardShortcut(".", modifiers: .command)
                            .help("Stop Claude's current step (⌘.)")
                        }
                        Spacer()
                    }
                    .frame(maxWidth: ColumnTextView.maxColumn)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                }
            }
    }
}

// MARK: - AppKit text view

struct TranscriptTextView: NSViewRepresentable {
    let content: TranscriptContent

    func makeCoordinator() -> Coordinator { Coordinator(openURL: { NSWorkspace.shared.open($0) }) }

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
struct WorkingRow: View {
    let tool: ToolCall?
    let since: Date?
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
        guard let tool else { return "Thinking…" }
        return "Running \(ToolStyle.displayName(tool.name))…"
    }

    private func elapsed(_ start: Date, _ now: Date) -> String { Format.elapsed(since: start, now: now) }
}
