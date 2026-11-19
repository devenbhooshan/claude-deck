import Foundation

/// A number of Claude calls a day, counted in user defaults under "<name>-<yyyy-MM-dd>" (local day).
struct DailyBudget {
    let name: String
    let limit: Int
    var defaults: UserDefaults = .standard

    func key(on day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(name)-" + f.string(from: day)
    }

    func used(on day: Date = Date()) -> Int { defaults.integer(forKey: key(on: day)) }

    func available(on day: Date = Date()) -> Bool { used(on: day) < limit }

    func spend(on day: Date = Date()) { defaults.set(used(on: day) + 1, forKey: key(on: day)) }
}

/// Sessions whose task naming was skipped (no budget left, one already running, or the call
/// failed), to try again later instead of waiting for your next message.
struct NamingRetries: Equatable {
    /// How long to wait after a failed call, so a broken login can't burn the budget.
    static let afterFailure: TimeInterval = 300

    private(set) var pending: [String: Date] = [:]

    /// Try again from `now` on (skipped), or after a pause (failed). Keeps an earlier time.
    mutating func skipped(_ sessionId: String, now: Date = Date(), failed: Bool = false) {
        let at = failed ? now.addingTimeInterval(Self.afterFailure) : now
        pending[sessionId] = min(pending[sessionId] ?? at, at)
    }

    mutating func done(_ sessionId: String) { pending[sessionId] = nil }

    /// The sessions due to try again, oldest first; they leave the list (a skip adds them back).
    mutating func due(now: Date = Date()) -> [String] {
        let ids = pending.filter { $0.value <= now }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
        for id in ids { pending[id] = nil }
        return ids
    }
}
