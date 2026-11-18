import Foundation

/// A standing instruction you'd otherwise retype ("short and crisp", "no em dashes"): inserted
/// from the "/" menu, or added to every message a session is sent from Deck.
struct Snippet: Codable, Identifiable, Equatable {
    /// Everywhere, or only in one session (by session id).
    enum Scope: Hashable {
        case global
        case session(String)
    }

    var id: String
    var name: String
    var text: String
    var scope: Scope

    init(id: String = UUID().uuidString, name: String, text: String, scope: Scope = .global) {
        self.id = id
        self.name = name
        self.text = text
        self.scope = scope
    }

    /// What's typed after "/" to insert it: "/s short-and-crisp".
    var command: String { "/s " + Snippet.slug(name) }

    func applies(to session: String?) -> Bool {
        switch scope {
        case .global: true
        case .session(let id): id == session
        }
    }

    /// "Short and crisp!" → "short-and-crisp".
    static func slug(_ name: String) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.isEmpty ? "snippet" : words.joined(separator: "-")
    }

    private enum CodingKeys: String, CodingKey { case id, name, text, scope }

    /// The scope is saved as "global" or the session's id.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "global"
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
                  name: try c.decode(String.self, forKey: .name), text: try c.decode(String.self, forKey: .text),
                  scope: scope == "global" ? .global : .session(scope))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(text, forKey: .text)
        switch scope {
        case .global: try c.encode("global", forKey: .scope)
        case .session(let id): try c.encode(id, forKey: .scope)
        }
    }
}

/// Every snippet, and which ones each session adds to every message.
struct SnippetLibrary: Codable, Equatable {
    var snippets: [Snippet] = []
    /// Session id → ids of the snippets put before every message sent to it from Deck.
    var everyMessage: [String: [String]] = [:]

    init(snippets: [Snippet] = [], everyMessage: [String: [String]] = [:]) {
        self.snippets = snippets
        self.everyMessage = everyMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(snippets: try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? [],
                  everyMessage: try c.decodeIfPresent([String: [String]].self, forKey: .everyMessage) ?? [:])
    }

    /// The ones you can use in a session: global ones and its own, by name.
    func available(for session: String?) -> [Snippet] {
        snippets.filter { $0.applies(to: session) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The snippets added to every message sent to `session`, in the order they're added.
    func standing(for session: String) -> [Snippet] {
        let ids = everyMessage[session] ?? []
        return snippets.filter { ids.contains($0.id) && $0.applies(to: session) }
    }

    /// The message as sent: the session's standing snippets, then a blank line, then the message.
    /// Slash commands are sent as typed (anything before them would break them).
    func prepend(_ message: String, for session: String) -> String {
        let standing = standing(for: session).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !standing.isEmpty, !message.hasPrefix("/") else { return message }
        let head = standing.joined(separator: "\n")
        return message.isEmpty ? head : head + "\n\n" + message
    }

    /// Snippets as "/" menu rows, then the row that opens the Snippets sheet.
    func commands(for session: String?) -> [SlashCommand] {
        available(for: session).map {
            SlashCommand(command: $0.command, description: $0.text.replacingOccurrences(of: "\n", with: " "),
                         source: $0.scope == .global ? "Snippet" : "Snippet · this session", kind: .snippet, insert: $0.text)
        } + [Snippets.manageCommand]
    }

    /// Adds a snippet, or replaces the one with its id.
    mutating func save(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i] = snippet } else { snippets.append(snippet) }
    }

    /// Removes a snippet, and stops adding it to messages.
    mutating func delete(_ id: String) {
        snippets.removeAll { $0.id == id }
        for (session, ids) in everyMessage { setEveryMessage(session, ids.filter { $0 != id }) }
    }

    /// Turns a snippet's "add to every message" on or off for a session.
    mutating func setEveryMessage(_ session: String, _ id: String, on: Bool) {
        var ids = (everyMessage[session] ?? []).filter { $0 != id }
        if on { ids.append(id) }
        setEveryMessage(session, ids)
    }

    private mutating func setEveryMessage(_ session: String, _ ids: [String]) {
        everyMessage[session] = ids.isEmpty ? nil : ids
    }
}

/// `snippets.json` in Deck's Application Support folder.
enum Snippets {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeDeck")
    static var fileURL: URL { dir.appendingPathComponent("snippets.json") }

    /// The "/" menu row that opens the Snippets sheet.
    static let manageCommand = SlashCommand(command: "/snippets", description: "Manage snippets…", source: "Deck", kind: .action)

    static func load() -> SnippetLibrary {
        guard let data = try? Data(contentsOf: fileURL),
              let library = try? JSONDecoder().decode(SnippetLibrary.self, from: data) else { return SnippetLibrary() }
        return library
    }

    static func save(_ library: SnippetLibrary) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
