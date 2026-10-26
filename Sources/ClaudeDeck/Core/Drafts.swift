import Foundation

/// What you've typed in a session's message box but not sent, and the files staged with it,
/// kept on disk so they survive switching sessions and quitting Deck.
struct Draft: Codable, Equatable {
    var text = ""
    /// Staged attachments, by path in Deck's attachment cache.
    var files: [String] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }

    init(text: String = "", files: [String] = []) {
        self.text = text
        self.files = files
    }

    /// Drafts were once saved as just their text.
    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                  files: try c.decodeIfPresent([String].self, forKey: .files) ?? [])
    }
}

/// One file, session id → draft.
enum Drafts {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck")
    static var fileURL: URL { dir.appendingPathComponent("drafts.json") }

    static func all() -> [String: Draft] {
        guard let data = try? Data(contentsOf: fileURL),
              let drafts = try? JSONDecoder().decode([String: Draft].self, from: data) else { return [:] }
        return drafts
    }

    static func draft(for session: String) -> Draft { all()[session] ?? Draft() }

    /// Changes a session's draft; an empty one is removed.
    static func update(_ session: String, _ change: (inout Draft) -> Void) {
        var drafts = all()
        var draft = drafts[session] ?? Draft()
        change(&draft)
        let new = draft.isEmpty ? nil : draft
        guard drafts[session] != new else { return }
        drafts[session] = new
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(drafts).write(to: fileURL, options: .atomic)
    }

    /// Every file some draft still holds (kept when old attachments are cleared away).
    static func files() -> Set<String> { Set(all().values.flatMap(\.files)) }
}
