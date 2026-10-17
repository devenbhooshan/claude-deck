import AppKit
import SwiftUI

// Shared design tokens and components. Every view should use these rather than local values.

enum Theme {
    static var accent: Color { Color(nsColor: Palette.accent) }
    static var waiting: Color { Color(nsColor: Palette.waiting) }
    static var busy: Color { Color(nsColor: Palette.busy) }
    static var idle: Color { Color(nsColor: Palette.idle) }
    static var success: Color { Color(nsColor: Palette.success) }
    static var danger: Color { Color(nsColor: Palette.danger) }
    static var surface: Color { Color(nsColor: Palette.surface) }
    static var panel: Color { Color(nsColor: Palette.panel) }

    typealias Radius = Palette.Radius

    static func isPermission(_ s: Session) -> Bool { SessionNav.isPermission(s) }

    static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .busy: busy
        case .idle: idle
        case .ended: .secondary
        }
    }

    static func shortPath(_ path: String) -> String { Format.shortPath(path) }
    static func ago(_ date: Date, now: Date = .now) -> String { Format.ago(date, now: now) }
}

struct StatusIcon: View {
    let status: SessionStatus
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            // A solid base under the tint, so the tile reads the same on any row background
            // (a see-through tint turned muddy on the selection highlight).
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Theme.panel)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Theme.color(status).opacity(status == .ended ? 0.12 : 0.16))
            switch status {
            case .busy:
                ProgressView().controlSize(.mini).scaleEffect(size / 26)
            default:
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(Theme.color(status))
            }
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch status {
        case .waiting: "hand.raised.fill"
        case .idle: "checkmark"
        case .busy, .ended: "clock"
        }
    }
}

/// The one set of controls for answering a permission prompt, used in the sidebar, the
/// session's approval card and the menu bar so they always look and behave the same.
struct ApprovalButtons: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    var size: ControlSize = .small

    var body: some View {
        HStack(spacing: 6) {
            if store.isAnswered(session) {
                Label("Sent", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else if PromptGuard.canAnswerHere(session) {
                Button("Allow") { store.respond(session, key: "enter") }
                    .buttonStyle(.deck(.primary, size: size))
                    .help("Allow once (⌥⌘↩ from any app)")
                Button("Always Allow") { store.respond(session, key: "2") }
                    .buttonStyle(.deck(.secondary, size: size))
                    .help("Allow, and don't ask again for this (option 2)")
                Button("Deny") { store.respond(session, key: "escape") }
                    .buttonStyle(.deck(.secondary, size: size))
                    .help("Deny (⌥⌘⌫ from any app)")
            } else {
                OpenTerminalButton(session: session, label: "Answer in Terminal")
                    .buttonStyle(.deck(.secondary, size: size))
                    .help(session.pendingTool == nil
                          ? "Deck can't see what this prompt is asking (set up approval details in the sidebar)"
                          : "This kind of prompt has its own options; answer it in the terminal")
            }
        }
    }
}

/// Brings the session's Ghostty terminal to the front; errors surface in the app's alert.
struct OpenTerminalButton: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    var label = "Open Terminal"

    var body: some View {
        Button {
            store.openTerminal(session)
        } label: {
            Label(label, systemImage: "apple.terminal")
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A small copy icon that confirms with a checkmark.
struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.deckBorderless)
        .font(.caption)
        .foregroundStyle(copied ? Theme.success : Color.secondary)
        .help("Copy")
    }
}

/// Shows a copy button on hover and adds "Copy Message" to the context menu.
struct Copyable: ViewModifier {
    let text: String
    var alignment: Alignment = .topTrailing
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                CopyButton(text: text)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(.background.opacity(0.9)))
                    .opacity(hovering ? 1 : 0)
                    .offset(y: -6)
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy Message") { Clipboard.copy(text) }
            }
    }
}

extension View {
    func copyable(_ text: String, alignment: Alignment = .topTrailing) -> some View {
        modifier(Copyable(text: text, alignment: alignment))
    }
}

/// The app's one button look: primary (filled accent), secondary (quiet fill, normal text),
/// link (accent text). Toolbar buttons stay native.
struct DeckButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, link }
    var kind: Kind = .secondary
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        DeckButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct DeckButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DeckButtonStyle.Kind
    let size: ControlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let small = size == .small || size == .mini
        let large = size == .large
        configuration.label
            .font(small ? .caption.weight(.medium) : .callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, kind == .link ? 0 : (small ? 9 : large ? 14 : 12))
            .padding(.vertical, kind == .link ? 0 : (small ? 4 : large ? 7 : 6))
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(background))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointingHand(isEnabled)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .link: hovering && isEnabled ? Theme.accent.opacity(0.75) : Theme.accent
        }
    }

    private var background: Color {
        let hover = hovering && isEnabled
        switch kind {
        case .primary: return hover ? Theme.accent.opacity(0.88) : Theme.accent
        case .secondary: return Color.primary.opacity(hover ? 0.11 : 0.07)
        case .link: return .clear
        }
    }
}

/// For custom-drawn buttons (icons, chips, rows): no look of its own, plus the pointing hand,
/// a press dim and the disabled fade.
struct DeckPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckPlainBody(configuration: configuration)
    }
}

private struct DeckPlainBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.45))
            .pointingHand(isEnabled)
    }
}

/// The native borderless look (menu bar panel, small icon buttons) with the pointing hand.
struct DeckBorderlessButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckBorderlessBody(configuration: configuration)
    }
}

private struct DeckBorderlessBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(configuration).buttonStyle(.borderless).pointingHand(isEnabled)
    }
}

extension ButtonStyle where Self == DeckPlainButtonStyle {
    static var deckPlain: DeckPlainButtonStyle { DeckPlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == DeckBorderlessButtonStyle {
    static var deckBorderless: DeckBorderlessButtonStyle { DeckBorderlessButtonStyle() }
}

/// Shows the pointing-hand cursor while the pointer is over something clickable. (SwiftUI's
/// pointerStyle needs macOS 15.)
struct PointingHandCursor: ViewModifier {
    var enabled = true
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    inside = true
                    if enabled { NSCursor.pointingHand.set() }
                case .ended:
                    if inside { NSCursor.arrow.set() }
                    inside = false
                }
            }
            .onDisappear { if inside { NSCursor.arrow.set() } }
    }
}

extension View {
    func pointingHand(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

extension ButtonStyle where Self == DeckButtonStyle {
    static func deck(_ kind: DeckButtonStyle.Kind = .secondary, size: ControlSize = .regular) -> DeckButtonStyle {
        DeckButtonStyle(kind: kind, size: size)
    }
}

/// One-click Allow / Deny for a waiting session (sidebar rows and the floating dock), or an
/// Answer button when the prompt can only be answered in the terminal.
struct QuickApproval: View {
    @Environment(SessionStore.self) private var store
    let session: Session

    var body: some View {
        if store.isAnswered(session) {
            Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary).help("Sent")
        } else if PromptGuard.canAnswerHere(session) {
            HStack(spacing: 4) {
                iconButton("checkmark", tint: Theme.accent, filled: true, help: "Allow: \(request)") {
                    store.respond(session, key: "enter")
                }
                iconButton("xmark", tint: .secondary, filled: false, help: "Deny") {
                    store.respond(session, key: "escape")
                }
            }
        } else {
            Button("Answer") { store.openTerminal(session) }
                .buttonStyle(.deck(.secondary, size: .mini))
                .help("This prompt is answered in the terminal")
        }
    }

    private var request: String {
        session.pendingTool.map { "\(ToolStyle.displayName($0.name)): \($0.summary)" } ?? "the open prompt"
    }

    private func iconButton(_ symbol: String, tint: Color, filled: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .white : tint)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(filled ? tint : Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .help(help)
    }
}

/// Deck's tabs: the selected one carries the accent tint (like the selected session in the
/// sidebar); the others highlight on hover. Optional counts sit in small badges.
struct DeckTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var count: Int? = nil
        var help: String? = nil
    }

    let items: [Item]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                DeckTab(title: item.title, count: item.count, selected: item.value == selection, help: item.help) {
                    selection = item.value
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

private struct DeckTab: View {
    let title: String
    let count: Int?
    let selected: Bool
    let help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.callout.weight(selected ? .semibold : .medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.08)))
                }
            }
            .foregroundStyle(selected ? Theme.accent : (hovering ? Color.primary : Color.secondary))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : (hovering ? Color.primary.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.deckPlain)
        .onHover { hovering = $0 }
        .help(help ?? title)
    }
}

/// The theme's own sidebar colour, when it has one (Classic keeps the system's). It reads the
/// saved theme itself, so a switch repaints the sidebar even if the list view is reused.
struct ThemedSidebar: ViewModifier {
    @AppStorage(DeckThemes.key) private var theme = DeckTheme.classic.rawValue

    func body(content: Content) -> some View {
        let color = Palette.sidebar(for: DeckTheme(rawValue: theme) ?? .classic)
        content
            .scrollContentBackground(color == nil ? .automatic : .hidden)
            .background(color.map { Color(nsColor: $0) } ?? .clear)
    }
}
