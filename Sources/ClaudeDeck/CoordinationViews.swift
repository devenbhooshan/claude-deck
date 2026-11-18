import SwiftUI

/// Everything waiting on you across sessions, answered in place: prompts, messages a session
/// drafted for another, and questions a session stopped on.
struct InboxView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        let items = store.inbox
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Theme.success)
                        Text("Nothing is waiting on you").font(.title3.weight(.medium))
                        Text("Prompts, questions and messages sessions draft for each other show up here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                ForEach(items) { item in
                    InboxCard(item: item)
                }
            }
            .frame(maxWidth: 760)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Needs You")
        .navigationSubtitle(items.isEmpty ? "All clear" : "\(items.count) waiting")
    }
}

private struct InboxCard: View {
    @Environment(SessionStore.self) private var store
    let item: Inbox.Item
    @State private var reply = ""
    @State private var attachments: [Attachment] = []

    private var session: Session { item.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusIcon(status: session.status, size: 20)
                Button { store.selectedId = session.id } label: {
                    Text(session.displayTitle).font(.headline)
                }
                .buttonStyle(.deckPlain)
                .help("Open this session")
                if session.sessionId == store.coordinatorId { CoordinatorBadge() }
                Text(kind).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if canDismiss {
                    Button { store.dismiss(item) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.deckBorderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var kind: String {
        switch item {
        case .prompt: Theme.isPermission(session) ? "wants to run a tool" : "is waiting for \(session.waitingFor ?? "you")"
        case .question: "asked you"
        case .handoff(_, let h): h.newSession ? "asks you to start a session, \(h.target)" : "drafted a message for \(h.target)"
        }
    }

    private var tint: Color {
        switch item {
        case .prompt: Theme.waiting
        case .question: Theme.idle
        case .handoff: Theme.accent
        }
    }

    private var canDismiss: Bool { if case .prompt = item { false } else { true } }

    @ViewBuilder private var content: some View {
        switch item {
        case .prompt:
            if let tool = session.pendingTool {
                Text(tool.summary)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            ApprovalButtons(session: session, size: .regular)
        case .question(_, let question):
            Text(LocalizedStringKey(question))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            MessageBox(draft: $reply, attachments: $attachments, draftKey: "inbox:" + session.sessionId,
                       placeholder: "Reply to \(session.displayTitle)…", hint: "↩ send to \(session.displayTitle)",
                       autofocus: false, onSend: sendReply) { EmptyView() }
                .padding(.horizontal, -20)
        case .handoff(_, let h):
            HandoffActions(handoff: h)
        }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments
        reply = ""
        attachments = []
        Task {
            do { try await store.send(text, attachments: staged, to: session) } catch {
                reply = text
                attachments = staged
                store.lastError = error.localizedDescription
            }
        }
    }
}

/// A handoff's text, and Send / Edit First, as on its card in the transcript.
private struct HandoffActions: View {
    @Environment(SessionStore.self) private var store
    let handoff: Handoff

    private var target: Session? { SessionAddress.resolve(handoff.target, in: store.live) }

    var body: some View {
        Text(handoff.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.accent.opacity(0.06)))
        HStack(spacing: 8) {
            if !handoff.isTypeable {
                Label("Deck won't type this: it would run as a command", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if handoff.newSession {
                Button("Start Session") { store.sendHandoff(handoff) }
                    .buttonStyle(.deck(.primary))
                    .help("Start \(handoff.target) and send this as your first message")
                Button("Edit First") { store.editHandoff(handoff) }
                    .buttonStyle(.deck(.secondary))
                    .help("Change the name, folder or first message before starting")
            } else {
                Button("Send to \(handoff.target)") { store.sendHandoff(handoff) }
                    .buttonStyle(.deck(.primary))
                    .disabled(target == nil)
                    .help(target == nil ? "No running session is called \(handoff.target)" : "Type this into \(handoff.target) as you")
                Button("Edit First") { store.editHandoff(handoff) }
                    .buttonStyle(.deck(.secondary))
                    .disabled(target == nil)
                    .help("Open \(handoff.target) with this in its message box")
            }
            Button("Copy") { Clipboard.copy(handoff.text) }
                .buttonStyle(.deck(.secondary))
            Spacer()
        }
    }
}

/// Marks the coordinating session wherever it's listed.
struct CoordinatorBadge: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .help("Coordinator: ⌘0 opens it, and its messages for other sessions come first in Needs You")
    }
}

/// Every message sessions sent each other, and you sent from Deck, newest first.
struct CommsView: View {
    @Environment(SessionStore.self) private var store
    @State private var sender: String?

    var body: some View {
        let all = store.comms.messages
        let shown = sender.map { s in all.filter { $0.from == s || $0.to == s } } ?? all
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                let latest = CommsMessage.latestBySender(all)
                if !latest.isEmpty {
                    Text("Latest from each").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(latest) { m in
                        Button { sender = sender == m.from ? nil : m.from } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(m.from).font(.callout.weight(.semibold)).frame(width: 140, alignment: .leading).lineLimit(1)
                                Text(m.summary ?? SessionLoader.oneLine(m.text)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Theme.ago(m.at)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(sender == m.from ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.deckPlain)
                        .help(sender == m.from ? "Show everyone's messages" : "Show only messages to and from \(m.from)")
                    }
                    Divider().padding(.vertical, 6)
                }
                if shown.isEmpty {
                    Text("No messages between sessions yet. They appear here when one session sends another a message.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
                ForEach(shown) { m in CommsRow(message: m) }
            }
            .frame(maxWidth: 760)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Messages Between Sessions")
        .navigationSubtitle(sender.map { "To and from \($0)" } ?? "\(all.count) messages")
        .toolbar {
            if sender != nil {
                ToolbarItem { Button("Show All") { sender = nil }.help("Show everyone's messages") }
            }
        }
    }
}

private struct CommsRow: View {
    @Environment(SessionStore.self) private var store
    let message: CommsMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                name(message.from)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                name(message.to)
                Spacer()
                Text(message.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .help(message.at.formatted(date: .complete, time: .standard))
            }
            if let summary = message.summary, !summary.isEmpty {
                Text(summary).font(.callout.weight(.medium))
            }
            Text(message.text)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.text.count > 240 || message.text.filter(\.isNewline).count > 2 {
                Button(expanded ? "Show Less" : "Show All") { expanded.toggle() }
                    .buttonStyle(.deck(.link))
                    .font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panel))
    }

    /// A session's name, opening it when it's running.
    @ViewBuilder private func name(_ n: String) -> some View {
        if let s = SessionAddress.resolve(n, in: store.live) {
            Button { store.selectedId = s.id } label: {
                HStack(spacing: 3) {
                    Text(n).font(.callout.weight(.semibold))
                    if s.sessionId == store.coordinatorId { CoordinatorBadge() }
                }
            }
            .buttonStyle(.deckPlain)
            .help("Open \(n)")
        } else {
            Text(n).font(.callout.weight(.semibold)).foregroundStyle(n == "You" ? Theme.accent : .primary)
        }
    }
}

/// Floats over the coordinator's conversation: its latest task board, so you can see where
/// each piece of work stands without leaving it. Collapses to a one-line summary.
struct TaskBoardPanel: View {
    @Environment(SessionStore.self) private var store
    let coordinator: Session
    @AppStorage("taskBoardExpanded") private var expanded = true
    @AppStorage("taskBoardShowDone") private var showDone = false
    /// The board instructions last typed into the coordinator, to offer newer ones.
    @AppStorage("taskBoardInstructions") private var sentInstructions = ""

    private func sendInstructions() {
        Task {
            do {
                try await store.send(TaskBoard.request, to: coordinator)
                sentInstructions = TaskBoard.request
            } catch { store.lastError = error.localizedDescription }
        }
    }

    var body: some View {
        let board = coordinator.tasks
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.callout).foregroundStyle(Theme.accent)
                    Text("Tasks").font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if let board { counts(board) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.deckPlain)
            .help(expanded ? "Collapse" : "Show the coordinator's tasks")
            if expanded {
                Divider()
                if let board, !board.items.isEmpty {
                    list(board)
                } else {
                    empty
                }
            }
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.panel)
            .shadow(color: .black.opacity(0.15), radius: 14, y: 4))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func list(_ board: TaskBoard) -> some View {
        // Snoozed tasks stay out of sight here (the board itself is the coordinator's) until the snooze ends.
        let shown = board.items.filter { !store.board.isSnoozed($0) }
        let done = shown.filter { $0.state == .done }
        let states = TaskItem.State.allCases.filter { $0 != .done || showDone }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(states, id: \.self) { state in
                        let tasks = shown.filter { $0.state == state }
                        if !tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(TaskRow.section(state)) · \(tasks.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(state == .todo ? .secondary : TaskRow.color(state))
                                    .padding(.horizontal, 6)
                                ForEach(tasks) { TaskRow(task: $0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Text("Updated \(Theme.ago(board.at))").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                let stale = sentInstructions != TaskBoard.request
                Button(stale ? "Send New Board Instructions" : "Resend Instructions") { sendInstructions() }
                    .buttonStyle(.deck(.link)).font(.caption.weight(stale ? .semibold : .regular))
                    .help(stale ? "Deck's board format changed: type the new instructions into the coordinator"
                                : "Type the board instructions into the coordinator again")
                if !done.isEmpty {
                    Button(showDone ? "Hide Done" : "Show \(done.count) Done") { showDone.toggle() }
                        .buttonStyle(.deck(.link)).font(.caption)
                }
                let snoozed = store.board.snoozedCount
                if snoozed > 0 {
                    Button("Wake \(snoozed) Snoozed") { store.board.wakeAll() }
                        .buttonStyle(.deck(.link)).font(.caption)
                        .help("Show the tasks you snoozed again now")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No task board yet. Ask the coordinator to keep one, and its latest board shows here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ask for a Task Board") { sendInstructions() }
            .buttonStyle(.deck(.secondary))
            .help("Types a request into the coordinator explaining the board's format")
        }
        .padding(12)
    }

    /// How many need you, in plain words, and how many are moving.
    private func counts(_ board: TaskBoard) -> some View {
        let you = board.items.filter { $0.state == .you }.count
        let doing = board.items.filter { $0.state == .doing }.count
        return HStack(spacing: 4) {
            if you > 0 {
                Text("\(you) need you").foregroundStyle(Theme.waiting).fontWeight(.semibold)
            }
            if you > 0 && doing > 0 { Text("·").foregroundStyle(.tertiary) }
            if doing > 0 {
                Text("\(doing) in progress").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }
}

private struct TaskRow: View {
    @Environment(SessionStore.self) private var store
    let task: TaskItem
    @State private var answer = ""
    @FocusState private var answering: Bool

    private var pending: BoardEdit? { store.board.pending(task) }

    private func edit(_ action: BoardEdit.Action) {
        withAnimation(.snappy) { store.editTask(task, action) }
    }

    private func sendAnswer() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        edit(.answer(text))
        answer = ""
        answering = false
    }

    /// A group's heading: what the state means for you.
    static func section(_ s: TaskItem.State) -> String {
        switch s {
        case .you: "Waiting on you"
        case .blocked: "Blocked on others"
        case .doing: "In progress"
        case .todo: "Up next"
        case .done: "Done"
        }
    }

    static func color(_ s: TaskItem.State) -> Color {
        switch s {
        case .you: Theme.waiting
        case .blocked: Theme.danger
        case .doing: Theme.busy
        case .todo: .secondary
        case .done: Theme.success
        }
    }

    private var icon: String {
        switch task.state {
        case .you: "person.fill.questionmark"
        case .blocked: "exclamationmark.octagon.fill"
        case .doing: "circle.dotted.circle"
        case .todo: "circle"
        case .done: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.callout).foregroundStyle(Self.color(task.state))
                .frame(width: 16)
                .help(task.state.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout.weight(.medium)).textSelection(.enabled)
                    .foregroundStyle(task.state == .done ? .secondary : .primary)
                    .strikethrough(task.state == .done, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = task.note {
                    if task.state == .you {
                        // What you need to do: the point of the row, so it reads first after the title.
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2.weight(.bold))
                            Text(note).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.waiting)
                    } else {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
                if let pending {
                    sentBadge(pending)
                } else if task.state == .you && store.coordinator != nil {
                    answerControls
                }
                HStack(spacing: 6) {
                    if let name = task.session { sessionChip(name) }
                    if task.state == .you, pending == nil, let c = store.coordinator {
                        Button("What do you need?") {
                            Task {
                                do { try await store.send(TaskBoard.ask(about: task), to: c) } catch { store.lastError = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.deck(.link)).font(.caption)
                        .help("Ask the coordinator exactly what it needs from you on this task")
                    }
                }
            }
            Spacer(minLength: 0)
            if task.state != .done, pending == nil, store.coordinator != nil { controlsMenu }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pending == nil ? 1 : 0.75)
    }

    /// Sent to the coordinator, waiting for its next board to show it.
    private func sentBadge(_ edit: BoardEdit) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill").font(.caption2)
            Text(edit.pendingLabel).fontWeight(.semibold)
            if case .answer(let a) = edit.action {
                Text("“\(SessionLoader.oneLine(a))”").lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Theme.accent.opacity(0.12)))
        .help("Typed to the coordinator: \(edit.line)\nShown until its next board reflects it.")
    }

    /// On a task waiting on you: say you did it, or answer it in a few words.
    private var answerControls: some View {
        HStack(spacing: 6) {
            Button { edit(.didIt) } label: {
                Label("I Did It", systemImage: "checkmark")
            }
            .buttonStyle(.deck(.primary, size: .small))
            .help("Tell the coordinator you've done this yourself")
            TextField("Answer…", text: $answer)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($answering)
                .onSubmit(sendAnswer)
                .help("A short answer for the coordinator (Return sends it). It's kept in the decisions log.")
            if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Send", action: sendAnswer)
                    .buttonStyle(.deck(.secondary, size: .small))
            }
        }
        .padding(.top, 3)
    }

    /// The task's controls: each becomes one line typed to the coordinator.
    private var controlsMenu: some View {
        Menu {
            Button { edit(.done) } label: { Label("Mark Done", systemImage: "checkmark.circle") }
            if task.state == .blocked {
                Button { edit(.unblock) } label: { Label("Unblock", systemImage: "lock.open") }
            }
            if task.state != .todo {
                Button { edit(.later) } label: { Label("Move to Later", systemImage: "arrow.uturn.down") }
            }
            Divider()
            Button { edit(.snooze(hours: 1)) } label: { Label("Snooze for an Hour", systemImage: "moon.zzz") }
            Button { edit(.snooze(hours: 24)) } label: { Label("Snooze for a Day", systemImage: "moon.zzz") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.callout).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change this task: Deck tells the coordinator, and its next board shows it")
    }

    /// The session doing it, with its live state; opens it when it's running.
    @ViewBuilder private func sessionChip(_ name: String) -> some View {
        if let s = SessionAddress.resolve(name, in: store.live) {
            Button { store.selectedId = s.id } label: {
                HStack(spacing: 4) {
                    Circle().fill(Theme.color(s.status)).frame(width: 6, height: 6)
                    Text(s.displayTitle).lineLimit(1)
                    Text("· \(s.status == .waiting ? "needs you" : s.status.label.lowercased())").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.deckPlain)
            .help("Open \(s.displayTitle)")
        } else {
            Text(name).font(.caption).foregroundStyle(.tertiary)
                .help("No running session is called \(name)")
        }
    }
}

/// A new-session card being changed before it starts.
struct StartDraft: Identifiable {
    let id = UUID()
    let handoff: Handoff
    let folder: String
}

/// Edit First on a new-session card: its name, folder and first message, then Start.
struct StartDraftSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft: StartDraft
    @State private var name = ""
    @State private var folder = ""
    @State private var prompt = ""

    private var canStart: Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty
            && Handoff(target: name, text: text, newSession: true).isTypeable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start a new session").font(.title3.weight(.semibold))
            Text("Opens a Ghostty window in the folder, starts Claude with this name and sends the first message as you.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Label("Name", systemImage: "character.cursor.ibeam").frame(width: 90, alignment: .leading)
                TextField("", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Label("Folder", systemImage: "folder").frame(width: 90, alignment: .leading)
                Text(Theme.shortPath(folder)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(folder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: folder)
                    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                }
                .buttonStyle(.deck(.secondary))
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("First message", systemImage: "text.bubble")
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 160, maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.deck(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    store.startHandoff(draft.handoff, name: name.trimmingCharacters(in: .whitespaces), folder: folder,
                                       prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.deck(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .help(canStart ? "Start the session" : "It needs a name and a first message that doesn't start with /, ! or -")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            name = draft.handoff.target
            folder = draft.folder
            prompt = draft.handoff.text
        }
    }
}
