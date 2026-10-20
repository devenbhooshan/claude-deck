import Foundation

// A tiny test kit: the Command Line Tools ship neither XCTest nor Swift Testing,
// so tests are plain functions run by Tests/main.swift (see test.sh).

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("✗ \(currentTest) — \(file):\(line) \(message())")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: String = #fileID, line: Int = #line) {
    expect(a == b, "expected \(b), got \(a)", file: file, line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    do { try body() } catch {
        failures += 1
        print("✗ \(name) — threw \(error)")
    }
}

/// Runs the main run loop until `condition` holds or `timeout` passes (for file watchers etc).
func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// A throwaway folder that stands in for ~/.claude and Deck's caches.
struct Sandbox {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ClaudePaths.home = root.appendingPathComponent("claude")
        PendingRequests.dir = root.appendingPathComponent("pending")
        AttachmentStore.dir = root.appendingPathComponent("attachments")
        ActivityIndex.dir = root.appendingPathComponent("activity")
        Policies.dir = root.appendingPathComponent("policies")
        try! FileManager.default.createDirectory(at: ClaudePaths.sessions, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: ClaudePaths.projects, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let url = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes JSONL (one JSON object per line) from dictionaries.
    @discardableResult
    func jsonl(_ relative: String, _ records: [[String: Any]]) -> URL {
        let lines = records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        return write(relative, lines.joined(separator: "\n") + "\n")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
