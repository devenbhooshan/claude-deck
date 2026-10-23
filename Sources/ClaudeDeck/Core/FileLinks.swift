import Foundation

/// Files Deck can show itself (PDFs, images, web pages, markdown it edits), and finding them in what Claude wrote,
/// so a path like `docs/report.pdf` or `~/Desktop/Screenshot 2026-10-21 at 9.57.47 AM.png` opens in Deck.
enum FileLinks {
    enum Kind: Equatable { case pdf, image, html, markdown }

    private static let kinds: [String: Kind] = [
        "pdf": .pdf,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image,
        "heic": .image, "heif": .image, "tif": .image, "tiff": .image, "bmp": .image,
        // A web view draws SVG best.
        "svg": .html, "html": .html, "htm": .html,
        "md": .markdown, "markdown": .markdown,
    ]

    static func kind(of url: URL) -> Kind? { kinds[url.pathExtension.lowercased()] }

    /// The transcript link that opens `path` in the viewer.
    static func link(to path: String) -> URL {
        var c = URLComponents()
        c.scheme = "deck"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url!
    }

    /// The file a transcript link points at: a viewer link, a file:// link, or a relative
    /// markdown link like `[report](docs/report.pdf)`. Only kinds Deck can show; nothing else is opened.
    static func file(for link: URL, cwd: String) -> URL? {
        let path: String?
        switch link.scheme?.lowercased() {
        case "deck" where link.host == "open":
            path = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        case "file": path = link.path
        case nil: path = link.path.removingPercentEncoding
        default: path = nil
        }
        guard let path, !path.isEmpty, let url = resolve(path, cwd: cwd), kind(of: url) != nil else { return nil }
        return url
    }

    private static let ext = kinds.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    /// A path without spaces: absolute, ~/, ./, ../ or relative to the session's folder.
    private static let plain = try! NSRegularExpression(
        pattern: #"(?<![^\s"'`(\[<])(?:~/|\.{1,2}/|/)?(?:[\w@+.,=-]+/)*[\w@+.,=-]+\.(?:"# + ext + #")(?!\.?[\w/-])"#,
        options: .caseInsensitive)
    /// An absolute or ~/ path with spaces, as screenshots have.
    private static let spaced = try! NSRegularExpression(
        pattern: #"(?<![^\s"'`(\[<])(?:~/|/)[^\n"'`<>|]*?\.(?:"# + ext + #")(?!\.?[\w/-])"#,
        options: .caseInsensitive)

    /// Paths in `text` to files that exist and Deck can show, with where they are in the text.
    static func find(in text: String, cwd: String,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [(NSRange, URL)] {
        var out: [(NSRange, URL)] = []
        let full = NSRange(text.startIndex..., in: text)
        for regex in [plain, spaced] {
            for m in regex.matches(in: text, range: full) where !out.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) {
                guard let url = resolve((text as NSString).substring(with: m.range), cwd: cwd), exists(url.path) else { continue }
                out.append((m.range, url))
            }
        }
        return out.sorted { $0.0.location < $1.0.location }
    }

    /// An absolute file URL for `path`, or nil for a relative path with no folder to resolve it in.
    static func resolve(_ path: String, cwd: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        guard !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL
    }
}
