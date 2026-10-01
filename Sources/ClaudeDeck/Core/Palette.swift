import AppKit

/// Design tokens shared by SwiftUI (via Theme) and AppKit drawing (the transcript).
enum Palette {
    static let accent = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) // Claude's terracotta
    static let waiting = NSColor(srgbRed: 0.93, green: 0.55, blue: 0.20, alpha: 1)
    static let busy = NSColor.systemBlue
    static let idle = NSColor.systemGreen
    static let success = NSColor.systemGreen.withAlphaComponent(0.75)
    static let danger = NSColor.systemRed.withAlphaComponent(0.85)

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
