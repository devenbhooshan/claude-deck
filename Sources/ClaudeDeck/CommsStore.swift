import Foundation
import Observation

/// Every message sessions sent each other (Claude Code's SendMessage), read from their
/// transcripts as they grow, plus what you sent from Deck. Newest first.
@MainActor
@Observable
final class CommsStore {
    private(set) var messages: [CommsMessage] = []

    /// How far each transcript has been read, and what it sent.
    @ObservationIgnored private var read: [String: (end: UInt64, mtime: Date, sent: [CommsMessage])] = [:]
    @ObservationIgnored private var mine: [CommsMessage] = []
    @ObservationIgnored private var busy = false
    private let queue = DispatchQueue(label: "comms", qos: .utility)

    func record(_ m: CommsMessage) {
        mine.append(m)
        publish()
    }

    /// Reads what's new in the running sessions' transcripts (only files that changed).
    func refresh(sessions: [Session]) {
        guard !busy else { return }
        let files = sessions.compactMap { s in s.transcriptURL.map { (url: $0, name: s.displayTitle) } }
        let known = read
        busy = true
        queue.async { [weak self] in
            var updates: [String: (end: UInt64, mtime: Date, sent: [CommsMessage])] = [:]
            for f in files {
                guard let mtime = try? f.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                let before = known[f.url.path]
                if before?.mtime == mtime { continue }
                // A long session's first read covers its latest part.
                let (lines, end) = TailReader.read(f.url, from: before?.end, maxBytes: 3_000_000)
                updates[f.url.path] = (end, mtime, (before?.sent ?? []) + CommsMessage.sent(in: lines, by: f.name))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard !updates.isEmpty else { return }
                for (k, v) in updates { self.read[k] = v }
                self.publish()
            }
        }
    }

    private func publish() {
        let merged = CommsMessage.merge(read.values.map(\.sent) + [mine])
        if merged != messages { messages = merged }
    }
}
