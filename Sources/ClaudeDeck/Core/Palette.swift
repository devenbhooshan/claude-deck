import AppKit

/// Deck's looks. Classic follows the system (light or dark) with Claude's terracotta; Midnight is
/// a dark ink theme with a violet accent.
enum DeckTheme: String, CaseIterable {
    case classic, midnight

    var name: String {
        switch self {
        case .classic: "Classic"
        case .midnight: "Midnight"
        }
    }

    /// The appearance it forces, if any (Midnight is always dark).
    var appearance: NSAppearance.Name? { self == .midnight ? .darkAqua : nil }
}

/// Design tokens shared by SwiftUI (via Theme) and AppKit drawing (the transcript), for the
/// current theme.
enum Palette {
    nonisolated(unsafe) static var theme: DeckTheme = .classic

    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static var accent: NSColor {
        theme == .midnight ? hex(0x8B7CFF) : NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) // Claude's terracotta
    }
    static var waiting: NSColor { theme == .midnight ? hex(0xFFB547) : NSColor(srgbRed: 0.93, green: 0.55, blue: 0.20, alpha: 1) }
    static var busy: NSColor { theme == .midnight ? hex(0x5AB0FF) : .systemBlue }
    static var idle: NSColor { theme == .midnight ? hex(0x4FD1A5) : .systemGreen }
    static var success: NSColor { theme == .midnight ? hex(0x4FD1A5, alpha: 0.8) : NSColor.systemGreen.withAlphaComponent(0.75) }
    static var danger: NSColor { theme == .midnight ? hex(0xFF6B7A) : NSColor.systemRed.withAlphaComponent(0.85) }
    /// Where you read: the transcript, lists and panels.
    static var surface: NSColor { theme == .midnight ? hex(0x0F1220) : .textBackgroundColor }
    /// Raised things on it: the message box, cards.
    static var panel: NSColor { theme == .midnight ? hex(0x171B2E) : .controlBackgroundColor }
    /// The sidebar, when the theme draws its own (nil: the system's).
    static var sidebar: NSColor? { sidebar(for: theme) }
    static func sidebar(for theme: DeckTheme) -> NSColor? { theme == .midnight ? hex(0x12162A) : nil }

    /// Three corner sizes for everything: keycaps and inner wells, cards, and large surfaces.
    enum Radius {
        static let small: CGFloat = 6   // keycaps, tool output wells
        static let medium: CGFloat = 10 // cards: tool groups, tables, code, thumbnails
        static let large: CGFloat = 16  // bubbles, composer, approval card, palettes, HUD
    }
}

enum Format {
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.replacingOccurrences(of: home, with: "~")
    }

    /// Compact age: "now", "5m", "3h", "2d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    /// Elapsed time for the working indicator: "42s", "3m 5s".
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
