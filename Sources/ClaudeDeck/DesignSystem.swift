import AppKit
import SwiftUI

// Shared design tokens and components. Every view should use these rather than local values.

enum Theme {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude's terracotta
    static let waiting = Color(red: 0.93, green: 0.55, blue: 0.20)
    static let busy = Color.blue
    static let idle = Color.green
    static let success = Color.green.opacity(0.75)
    static let danger = Color.red.opacity(0.85)

    /// Three corner sizes for everything: keycaps and inner wells, cards, and large surfaces.
    enum Radius {
        static let small: CGFloat = 6   // keycaps, tool output wells
        static let medium: CGFloat = 10 // cards: tool groups, tables, code, thumbnails
        static let large: CGFloat = 16  // bubbles, composer, approval card, palettes, HUD
    }

    /// Permission prompts can be answered with Allow / Deny; other waits (questions) need the terminal.
    static func isPermission(_ s: Session) -> Bool {
        s.waitingFor?.localizedCaseInsensitiveContains("permission") ?? false
    }

    static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .busy: busy
        case .idle: idle
        case .ended: .secondary
        }
    }

    static func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }
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
            } else if Theme.isPermission(session) {
                Button("Allow") { store.respond(session, key: "enter") }
                    .buttonStyle(.borderedProminent)
                    .help("Allow once (⌥⌘↩ from any app)")
                Button("Always Allow") { store.respond(session, key: "2") }
                    .help("Allow, and don't ask again for this (option 2)")
                Button("Deny") { store.respond(session, key: "escape") }
                    .help("Deny (⌥⌘⌫ from any app)")
            } else {
                OpenTerminalButton(session: session, label: "Answer in Terminal")
            }
        }
        .controlSize(size)
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
