import Foundation
import Observation

/// Deck's side of the coordinator's task board: changes you've sent that its board doesn't show
/// yet, snoozed tasks, and the decisions log it types back in after the coordinator compacts.
@MainActor
@Observable
final class BoardStore {
    private(set) var state = BoardState()
    /// Bumped once a minute or so, so snoozes that ended come back.
    private(set) var now = Date()
    @ObservationIgnored private var coordinatorId: String?
    @ObservationIgnored private var checkedMtime: Date?
    @ObservationIgnored private var checking = false

    /// Tasks hidden until their snooze ends.
    var snoozedCount: Int { state.snoozed.values.filter { $0 > now }.count }

    func pending(_ task: TaskItem) -> BoardEdit? { state.pending(task) }
    func isSnoozed(_ task: TaskItem) -> Bool { state.isSnoozed(task, now: now) }

    func record(_ edit: BoardEdit, coordinator: String) {
        use(coordinator)
        state.record(edit)
        state.save(coordinator)
        if case .answer(let a) = edit.action {
            Decisions.append(Decision(date: Decisions.day(edit.at), task: edit.task, answer: a), to: coordinator)
        }
    }

    /// Shows every snoozed task again.
    func wakeAll() {
        guard let id = coordinatorId else { return }
        state.snoozed = [:]
        state.save(id)
    }

    private func use(_ coordinator: String) {
        guard coordinator != coordinatorId else { return }
        coordinatorId = coordinator
        checkedMtime = nil
        state = BoardState.load(coordinator)
    }

    /// On each refresh: drops changes the board now shows and snoozes that ended, and types the
    /// decisions in again if the coordinator compacted since last time.
    func refresh(coordinator: Session?, onError: @escaping (String) -> Void) {
        guard let c = coordinator else { return }
        use(c.sessionId)
        now = Date()
        let next = state.reconciled(with: c.tasks, now: now)
        if next != state {
            state = next
            state.save(c.sessionId)
        }
        checkCompaction(c, onError: onError)
    }

    private func checkCompaction(_ c: Session, onError: @escaping (String) -> Void) {
        guard !checking, let url = c.transcriptURL,
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              mtime != checkedMtime else { return }
        checking = true
        let id = c.sessionId
        Task.detached(priority: .utility) {
            let latest = Compaction.latest(in: TailReader.read(url, from: nil, maxBytes: 256_000).0)
            await MainActor.run {
                guard self.coordinatorId == id else { self.checking = false; return }
                self.checkedMtime = mtime
                let check = BoardState.compaction(latest: latest, seen: self.state.compactionSeen)
                guard check.recap, let text = Decisions.recap(Decisions.load(id)) else {
                    self.checking = false
                    if self.state.compactionSeen != check.seen {
                        self.state.compactionSeen = check.seen
                        self.state.save(id)
                    }
                    return
                }
                Task {
                    defer { self.checking = false }
                    do {
                        try await Ghostty.send(text: text, images: [], to: c)
                        self.state.compactionSeen = check.seen
                        self.state.save(id)
                    } catch {
                        // Left unseen: tried again once the transcript changes (the prompt was answered).
                        onError("Couldn't give the coordinator its decisions after it compacted: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
