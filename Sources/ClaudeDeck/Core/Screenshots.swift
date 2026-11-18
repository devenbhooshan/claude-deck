import Foundation
import UniformTypeIdentifiers

/// macOS screenshots: where they're saved (for "Attach Latest Screenshot"), and the temporary
/// copies the floating thumbnail hands out, which macOS deletes as soon as the thumbnail closes.
enum Screenshots {
    /// The folder set in Screenshot.app's Options ("Save to"), or the Desktop when it isn't set
    /// or no longer exists.
    static func folder(location: String?, home: String = NSHomeDirectory()) -> URL {
        let desktop = URL(fileURLWithPath: home).appendingPathComponent("Desktop")
        guard let location = location?.trimmingCharacters(in: .whitespaces), !location.isEmpty else { return desktop }
        let expanded = location == "~" ? home : location.hasPrefix("~/") ? home + location.dropFirst() : location
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { return desktop }
        return URL(fileURLWithPath: expanded)
    }

    /// The screenshot folder from `com.apple.screencapture`'s `location` setting.
    static func folder() -> URL {
        folder(location: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"))
    }

    /// The most recently created image in `folder` (hidden files, such as the one macOS is still
    /// writing, are skipped), or nil when there's none.
    static func latest(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        let images = files.compactMap { url -> (URL, Date)? in
            guard isImage(url), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let created = values.creationDate else { return nil }
            return (url, created)
        }
        return images.max { $0.1 < $1.1 }?.0
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true
    }

    /// The folder macOS keeps a fresh screenshot in while its thumbnail is on screen.
    static let tempMarker = "NSIRD_screencaptureui"

    static func isTemporary(_ url: URL) -> Bool { url.path.contains(tempMarker) }

    /// Paths (or file URLs) of screenshot temp files in pasted text: a plain path, a path with
    /// `\ `-escaped spaces (as a terminal types it) or a `file://` URL.
    static func temporaryPaths(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        let ns = text as NSString
        return pathPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let found = ns.substring(with: m.range)
            let url = found.hasPrefix("file://") ? URL(string: found)
                : URL(fileURLWithPath: found.replacingOccurrences(of: "\\ ", with: " "))
            guard let url, let range = Range(m.range, in: text) else { return nil }
            return (range, url)
        }
    }

    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![^\s"'(<])(?:file://)?/[^\s"'<>]*"# + tempMarker
            + #"[^/\s"'<>]*/(?:\\ |[^/\n"'<>])*?\.(?:png|jpe?g|heic|tiff?|gif|webp|pdf|mov|mp4)(?![A-Za-z0-9])"#,
        options: [.caseInsensitive])

    /// Copies the screenshot temp files named in `text` with `attach` (into Deck's own cache,
    /// before macOS deletes them) and takes their paths out of the text. Paths that can't be
    /// copied (already gone) are left as typed.
    static func rescue<T>(_ text: String, attach: (URL) -> T?) -> (text: String, attached: [T]) {
        var out = text
        var attached: [T] = []
        for (range, url) in temporaryPaths(in: text).reversed() {
            guard let a = attach(url) else { continue }
            attached.insert(a, at: 0)
            // Drop one of the spaces around the path, so "see <path> here" becomes "see here".
            var upper = range.upperBound
            if upper < out.endIndex, out[upper] == " ",
               range.lowerBound == out.startIndex || out[out.index(before: range.lowerBound)].isWhitespace {
                upper = out.index(after: upper)
            }
            out.removeSubrange(range.lowerBound..<upper)
        }
        return (attached.isEmpty ? text : out.trimmingCharacters(in: .whitespacesAndNewlines), attached)
    }
}
