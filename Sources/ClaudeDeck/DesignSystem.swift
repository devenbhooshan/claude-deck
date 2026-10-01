import AppKit
import SwiftUI

// Shared design tokens and components. Every view should use these rather than local values.

enum Theme {
    static let accent = Color(nsColor: Palette.accent)
    static let waiting = Color(nsColor: Palette.waiting)
    static let busy = Color(nsColor: Palette.busy)
    static let idle = Color(nsColor: Palette.idle)
    static let success = Color(nsColor: Palette.success)
    static let danger = Color(nsColor: Palette.danger)

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
        .buttonStyle(.borderless)
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
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
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .link: Theme.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary: Color.primary.opacity(0.07)
        case .link: .clear
        }
    }
}

extension ButtonStyle where Self == DeckButtonStyle {
    static func deck(_ kind: DeckButtonStyle.Kind = .secondary, size: ControlSize = .regular) -> DeckButtonStyle {
        DeckButtonStyle(kind: kind, size: size)
    }
}
