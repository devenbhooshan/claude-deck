import Foundation

/// Writes the one record Deck adds to a transcript: a /rename-style custom title.
enum TranscriptWriter {
    /// Trims the name and folds newlines into spaces; nil if nothing is left.
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Appends the same record Claude Code writes for /rename.
    static func appendCustomTitle(_ name: String, sessionId: String, to url: URL) throws {
        let record: [String: Any] = ["type": "custom-title", "customTitle": name, "sessionId": sessionId]
        var line = try JSONSerialization.data(withJSONObject: record)
        line.append(UInt8(ascii: "\n"))
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }
}
