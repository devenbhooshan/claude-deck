import AppKit
import SwiftUI

/// A small always-on-top panel: Allow / Deny prompts in one click from any app (even over a
/// full-screen video) without Deck taking focus. Collapses to a pill; expands to every session.
@MainActor
final class FloatingDock {
    static let shared = FloatingDock()

    private var panel: DockPanel?
    private nonisolated static let shownKey = "dockShown"
    private nonisolated static let originKey = "dockTopLeft"

    var isShown: Bool { panel?.isVisible ?? false }

    /// Re-opens the dock on launch if it was open when Deck quit.
    func restore(store: SessionStore, usage: UsageModel) {
        if UserDefaults.standard.bool(forKey: Self.shownKey) { show(store: store, usage: usage) }
    }

    func toggle(store: SessionStore, usage: UsageModel) {
        isShown ? hide() : show(store: store, usage: usage)
    }

    private weak var store: SessionStore?
    private weak var usage: UsageModel?

    /// Rebuilds the dock (if it's showing) so it picks up a new theme.
    func reload() {
        guard let panel, panel.isVisible, let store, let usage else { panel?.close(); self.panel = nil; return }
        let origin = panel.frame.origin
        panel.close()
        self.panel = nil
        show(store: store, usage: usage)
        self.panel?.setFrameOrigin(origin)
    }

    func show(store: SessionStore, usage: UsageModel) {
        self.store = store
        self.usage = usage
        if panel == nil { makePanel(store: store, usage: usage) }
        if let host = panel?.contentView { fit(host.fittingSize) }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.shownKey)
    }

    /// Fits the panel to its content, keeping the top-left corner where you put it.
    fileprivate func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    private func makePanel(store: SessionStore, usage: UsageModel) {
        let panel = DockPanel()
        // Set first: the content reports its size as soon as it's attached.
        self.panel = panel
        // Where you left it, or the top-right corner of the main screen.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var topLeft = NSPoint(x: screen.maxX - 360, y: screen.maxY - 12)
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            let p = NSPoint(x: saved[0], y: saved[1])
            // Only if that spot is still on a connected screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }) { topLeft = p }
        }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - 44, width: 300, height: 44), display: false)

        let root = DockView { [weak self] in self?.hide() }
            .environment(store)
            .environment(usage)
            .environment(ActivityStore.shared)
        let host = FirstClickHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        panel.contentView = host

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let w = note.object as? NSWindow else { return }
            UserDefaults.standard.set([Double(w.frame.minX), Double(w.frame.maxY)], forKey: Self.originKey)
        }
    }
}

/// Floats above other apps on every Space (including full-screen ones) and never activates
/// Deck, so clicking it doesn't pull you out of what you're watching.
private final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isExcludedFromWindowsMenu = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click, even though the panel is never the key window.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DockView: View {
    @Environment(SessionStore.self) private var store
    @Environment(UsageModel.self) private var usage
    @AppStorage("dockExpanded") private var expanded = false
    @State private var hovering = false
    let close: () -> Void

    private var waiting: [Session] { store.live.filter { $0.status == .waiting } }
    /// Sessions with replies you haven't read (waiting ones already have their card).
    private var unread: [Session] { store.live.filter { $0.status != .waiting && store.unread($0) > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if !waiting.isEmpty || !unread.isEmpty {
                Divider().opacity(0.5)
                VStack(spacing: 2) {
                    ForEach(waiting) { s in WaitingCard(session: s, number: number(of: s)) }
                    ForEach(unread) { s in
                        Button { open(s) } label: {
                            UnreadCard(session: s, number: number(of: s), count: store.unread(s))
                        }
                        .buttonStyle(DockRowStyle())
                    }
                }
                .padding(6)
            }
            if expanded {
                Divider().opacity(0.5)
                sessionList
            }
        }
        .frame(width: compact ? nil : 340)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { FloatingDock.shared.fit($0) }
        .tint(Theme.accent)
    }

    /// Just the pill: nothing waiting or unread, and not expanded.
    private var compact: Bool { waiting.isEmpty && unread.isEmpty && !expanded }

    /// The pill: a spinner per session that's working (idle ones stay out of the way). Expand
    /// and hide appear on hover, or always while expanded.
    private var bar: some View {
        let working = store.live.filter { $0.status == .busy || $0.status == .background }
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            ForEach(working) { s in
                Button { open(s) } label: {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.deckPlain)
                .help(number(of: s).map { "\($0). \(s.displayTitle)" } ?? s.displayTitle)
            }
            if expanded {
                if let pct = usage.usage?.session?.percent {
                    Text("Plan \(pct)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Current session plan usage")
                }
                Spacer(minLength: 0)
            }
            if hovering || expanded {
                barButton(expanded ? "chevron.up" : "chevron.down", help: expanded ? "Collapse" : "Show all sessions") {
                    expanded.toggle()
                }
                barButton("xmark", help: "Hide the dock (⇧⌘D)", action: close)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.live.enumerated()), id: \.element.id) { i, s in
                Button { open(s) } label: {
                    SessionRow(session: s, number: i + 1)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DockRowStyle())
            }
            HStack {
                Button("Open Claude Deck") { store.bringToFront() }
                Spacer()
            }
            .buttonStyle(.deckBorderless)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .padding(.top, 4)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .help(help)
    }

    private func number(of s: Session) -> Int? {
        store.live.firstIndex(where: { $0.id == s.id }).map { $0 + 1 }
    }

    private func open(_ s: Session) {
        store.selectedId = s.id
        store.bringToFront()
    }
}

/// A prompt waiting on you: which session, what it wants, and one-click Allow / Deny.
private struct WaitingCard: View {
    let session: Session
    let number: Int?

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: .waiting, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(number.map { "\($0). \(session.displayTitle)" } ?? session.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(request)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            QuickApproval(session: session)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.waiting.opacity(0.08)))
        .help(request)
    }

    private var request: String {
        if let tool = session.pendingTool { return "\(ToolStyle.displayName(tool.name)): \(tool.summary)" }
        return "Waiting for \(session.waitingFor ?? "you")"
    }
}

/// New replies you haven't read: which session, the latest one, and how many. Clicking opens it.
private struct UnreadCard: View {
    let session: Session
    let number: Int?
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(number.map { "\($0). \(session.displayTitle)" } ?? session.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(session.lastReply ?? "New reply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(count > 99 ? "99+" : "\(count) new")
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Theme.accent))
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.accent.opacity(0.08)))
        .contentShape(Rectangle())
        .help("\(count) new \(count == 1 ? "reply" : "replies") from Claude. Click to open.")
    }
}

private struct DockRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0))
                .padding(.horizontal, 4))
            .onHover { hovering = $0 }
            .pointingHand()
    }
}
