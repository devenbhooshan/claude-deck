import CoreGraphics
import Foundation

// Lists a process's windows for scripts/screenshots.py: id, width, height, layer.
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where w[kCGWindowOwnerPID as String] as? Int == pid {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, Int(b["Width"] ?? 0), Int(b["Height"] ?? 0), w[kCGWindowLayer as String] ?? 0)
}
