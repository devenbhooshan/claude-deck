import Foundation

func dailyBudgetTests() {
    test("daily budget: counted per day, up to its limit") {
        let defaults = UserDefaults(suiteName: "deck-budget-tests")!
        defaults.removePersistentDomain(forName: "deck-budget-tests")
        let day = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!
        let next = day.addingTimeInterval(86400)
        let names = DailyBudget(name: "taskNameCalls", limit: 2, defaults: defaults)
        let summaries = DailyBudget(name: "activityCalls", limit: 2, defaults: defaults)
        expect(names.key(on: day).hasPrefix("taskNameCalls-2026-11-"))
        expect(names.available(on: day))
        names.spend(on: day); names.spend(on: day)
        expectEqual(names.used(on: day), 2)
        expect(!names.available(on: day), "spent")
        expect(summaries.available(on: day), "a separate budget")
        expect(names.available(on: next), "a new day")
        expect(DailyBudget(name: "x", limit: 1).used() >= 0)
        defaults.removePersistentDomain(forName: "deck-budget-tests")
    }

    test("naming retries: skipped now, failed after a pause, each once") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var r = NamingRetries()
        r.skipped("b", now: now)
        r.skipped("a", now: now.addingTimeInterval(-10))
        r.skipped("c", now: now, failed: true)
        expectEqual(r.due(now: now), ["a", "b"])
        expectEqual(r.due(now: now), [])
        expectEqual(r.due(now: now.addingTimeInterval(NamingRetries.afterFailure)), ["c"])
        r.skipped("d", now: now, failed: true)
        r.skipped("d", now: now)                       // a plain skip doesn't wait for the pause
        r.skipped("d", now: now.addingTimeInterval(60))  // keeps the earlier time
        expectEqual(r.pending["d"], now)
        r.done("d")
        expect(r == NamingRetries())
        expectEqual(r.due(), [])
    }
}
