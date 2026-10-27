import AppKit
import SwiftUI

/// Prompts Claude runs on a schedule on this Mac, and what each run found.
struct RoutinesSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Routine?
    @State private var isNew = false
    @State private var openRun: RoutineRun?
    @State private var expanded: Set<String> = []

    private var routines: RoutineStore { store.routines }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if routines.routines.isEmpty {
                        empty
                    } else {
                        ForEach(routines.routines) { r in
                            RoutineCard(routine: r, expanded: expanded.contains(r.id),
                                        onToggleRuns: { toggle(r.id) },
                                        onEdit: { isNew = false; editing = r },
                                        onOpen: { openRun = $0 })
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Routines run even when Deck is closed. Missed while asleep: they run when the Mac wakes.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 720, height: 680)
        .background(Theme.surface)
        .onAppear {
            routines.reload()
            if let id = store.openRun, let run = routines.runs.first(where: { $0.id == id }) {
                store.openRun = nil
                openRun = run
            }
            // New runs (with their own unread dot) stay visible; the count goes once you've looked.
            expanded = Set(routines.runs.filter(routines.isUnread).map(\.routine))
        }
        .onDisappear { routines.markSeen() }
        .sheet(item: $editing) { r in
            RoutineEditor(routine: r, isNew: isNew,
                          onSave: { routines.save($0) },
                          onDelete: { routines.delete(r) })
        }
        .sheet(item: $openRun) { run in RunSheet(run: run) }
        .alert("Couldn't schedule the routine", isPresented: Binding(get: { routines.lastError != nil },
                                                                 set: { if !$0 { routines.lastError = nil } })) {
            Button("OK") { routines.lastError = nil }
        } message: {
            Text(routines.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "alarm")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Routines").font(.title3.weight(.semibold))
                Text("Claude runs these on a schedule in their folder, without a terminal. Your policies check every tool call.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                isNew = true
                editing = Routine(folder: store.session(store.selectedId)?.cwd ?? NSHomeDirectory())
            } label: {
                Label("New Routine", systemImage: "plus")
            }
            .buttonStyle(.deck(.primary))
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No routines yet").font(.headline)
            Text("For example: every weekday at 9:00 in your app's folder, \u{201C}Check CI and open PRs and tell me what needs me.\u{201D}")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// One routine: switch, name, when, where and what it may do; its last result; Run Now and Edit.
struct RoutineCard: View {
    @Environment(SessionStore.self) private var store
    let routine: Routine
    let expanded: Bool
    let onToggleRuns: () -> Void
    let onEdit: () -> Void
    let onOpen: (RoutineRun) -> Void

    private var routines: RoutineStore { store.routines }
    private var runs: [RoutineRun] { routines.runs(of: routine.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(get: { routine.enabled }, set: { routines.setEnabled(routine, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .padding(.top, 2)
                    .help(routine.enabled ? "On: runs on schedule. Switch off to pause." : "Paused. Switch on to run on schedule.")
                VStack(alignment: .leading, spacing: 3) {
                    Text(routine.name.isEmpty ? "Untitled routine" : routine.name).font(.body.weight(.semibold))
                    Text("\(routine.schedule.summary) · \(Theme.shortPath(routine.folder)) · \(RoutineEditor.accessName(routine.access))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if routine.enabled {
                        TimelineView(.periodic(from: .now, by: 60)) { ctx in
                            Text("Next: " + RoutineCard.when(routine.schedule.next(after: ctx.date, lastRun: runs.first?.started), now: ctx.date))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Button { routines.runNow(routine) } label: { Label("Run Now", systemImage: "play.fill") }
                    .buttonStyle(.deck(size: .small))
                    .disabled(runs.first.map { $0.status == .running && !routines.isCutOff($0) } ?? false)
                    .help("Run it once now, in the background")
                Button("Edit…", action: onEdit).buttonStyle(.deck(size: .small))
            }
            .padding(12)

            if let last = runs.first {
                Divider().padding(.leading, 12)
                Button(action: onToggleRuns) {
                    HStack(spacing: 8) {
                        RunStatusIcon(run: last)
                        Text(RunRow.headline(last, cutOff: routines.isCutOff(last))).font(.callout).lineLimit(1)
                        Spacer()
                        Text(runs.count == 1 ? "1 run" : "\(runs.count) runs").font(.caption).foregroundStyle(.tertiary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.deckPlain)
                .help(expanded ? "Hide runs" : "Show recent runs")
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(runs.prefix(10)) { run in
                            RunRow(run: run, unread: routines.isUnread(run), cutOff: routines.isCutOff(run)) { onOpen(run) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(routine.enabled ? 1 : 0.75)
        .contextMenu {
            Button("Run Now") { routines.runNow(routine) }
            Button("Edit…", action: onEdit)
        }
    }

    /// "today 9:00", "tomorrow 9:00", "Mon 9:00".
    static func when(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return "tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " \(time)"
    }
}

struct RunStatusIcon: View {
    @Environment(SessionStore.self) private var store
    let run: RoutineRun

    var body: some View {
        Group {
            if run.status == .running && !store.routines.isCutOff(run) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                let (symbol, color): (String, Color) = switch run.status {
                case .succeeded: ("checkmark.circle.fill", Theme.success)
                case .failed, .running: ("exclamationmark.circle.fill", Theme.danger)
                case .timedOut: ("clock.badge.exclamationmark", Theme.waiting)
                }
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// One run in a routine's history; click to read the whole conversation.
struct RunRow: View {
    let run: RoutineRun
    let unread: Bool
    let cutOff: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                RunStatusIcon(run: run)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.started.formatted(date: .abbreviated, time: .shortened) + Self.details(run))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Self.headline(run, cutOff: cutOff)).font(.callout).lineLimit(1)
                }
                Spacer()
                if unread { Circle().fill(Theme.accent).frame(width: 7, height: 7).help("New") }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeckRowStyle())
        .help("Open this run")
    }

    static func headline(_ run: RoutineRun, cutOff: Bool) -> String {
        if cutOff { return "Cut off: the Mac slept or the run was stopped" }
        if run.status == .running { return "Running…" }
        let first = (run.result ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? (run.status == .succeeded ? "Finished" : "Failed") : first
    }

    static func details(_ run: RoutineRun) -> String {
        var parts: [String] = []
        if let end = run.finished { parts.append(Duration.seconds(end.timeIntervalSince(run.started)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))) }
        if let cost = run.cost { parts.append(String(format: "$%.2f", cost)) }
        if run.denied > 0 { parts.append("\(run.denied) refused") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }
}

/// A hover-highlighted row, like the floating dock's.
private struct DeckRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
            .pointingHand()
    }
}

// MARK: - Editor

struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    let isNew: Bool
    let onSave: (Routine) -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var capOn: Bool
    @State private var cap: Double

    init(routine: Routine, isNew: Bool, onSave: @escaping (Routine) -> Void, onDelete: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _capOn = State(initialValue: routine.budget != nil)
        _cap = State(initialValue: routine.budget ?? 2)
    }

    static func accessName(_ a: Routine.Access) -> String {
        switch a {
        case .readOnly: "Read-only"
        case .canEdit: "Can edit files"
        case .runCommands: "Can run commands"
        }
    }

    private static func accessDetail(_ a: Routine.Access) -> String {
        switch a {
        case .readOnly: "Reads and searches files and the web, and runs git and gh commands that only look. Anything else is refused."
        case .canEdit: "Also edits and writes files in the folder. Other commands are refused."
        case .runCommands: "Also runs any command, like tests and builds. Your policies are the guard: anything they block or would ask about is refused."
        }
    }

    private var canSave: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FileManager.default.fileExists(atPath: routine.folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Routine" : "Edit Routine").font(.title3.weight(.semibold)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        TextField("Morning PR check", text: $routine.name).textFieldStyle(.roundedBorder)
                    }
                    field("Folder") {
                        HStack {
                            Text(Theme.shortPath(routine.folder)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…") { chooseFolder() }.buttonStyle(.deck(size: .small))
                        }
                    }
                    field("Prompt", note: "What Claude should do each time. It starts fresh: say what to look at and what to report.") {
                        TextEditor(text: $routine.prompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 110)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Color.primary.opacity(0.15)))
                    }
                    field("When") { schedule }
                    field("Access", note: Self.accessDetail(routine.access)) {
                        Picker("", selection: $routine.access) {
                            ForEach(Routine.Access.allCases, id: \.self) { Text(Self.accessName($0)).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if routine.access == .runCommands && !PolicyHook.isInstalled {
                            Label("Policies are off, so nothing guards the commands. Turn them on in Policies.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Theme.waiting)
                        }
                    }
                    HStack(alignment: .top, spacing: 24) {
                        field("Model") {
                            Picker("", selection: $routine.model) {
                                Text("Default").tag("")
                                Text("Opus").tag("opus")
                                Text("Sonnet").tag("sonnet")
                                Text("Haiku").tag("haiku")
                            }
                            .labelsHidden().frame(width: 130)
                        }
                        field("Spending cap") {
                            HStack(spacing: 6) {
                                Toggle("", isOn: $capOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                if capOn {
                                    Text("$")
                                    TextField("", value: $cap, format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).frame(width: 60)
                                    Text("per run").foregroundStyle(.secondary)
                                } else {
                                    Text("No cap").foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        }
                        field("Time limit") {
                            Stepper(value: $routine.timeoutMinutes, in: 5...240, step: 5) {
                                Text("\(routine.timeoutMinutes) min").monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }.buttonStyle(.deck())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.deck()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    var r = routine
                    r.name = r.name.trimmingCharacters(in: .whitespaces)
                    r.budget = capOn ? max(0.01, cap) : nil
                    onSave(r)
                    dismiss()
                }
                .buttonStyle(.deck(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 620, height: 680)
        .background(Theme.surface)
        .confirmationDialog("Delete \u{201C}\(routine.name)\u{201D}?", isPresented: $confirmDelete) {
            Button("Delete Routine and Its Runs", role: .destructive) { onDelete(); dismiss() }
        } message: {
            Text("It stops running and its run history is removed. The conversations stay in Claude Code's history.")
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $routine.schedule.kind) {
                Text("At a time of day").tag(RoutineSchedule.Kind.daily)
                Text("Every few hours").tag(RoutineSchedule.Kind.interval)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            if routine.schedule.kind == .daily {
                HStack(spacing: 12) {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: routine.schedule.hour, minute: routine.schedule.minute, second: 0, of: Date())! },
                        set: {
                            routine.schedule.hour = Calendar.current.component(.hour, from: $0)
                            routine.schedule.minute = Calendar.current.component(.minute, from: $0)
                        }), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            let on = routine.schedule.weekdays.isEmpty || routine.schedule.weekdays.contains(day)
                            Button { toggleDay(day) } label: {
                                Text(RoutineSchedule.weekdayNames[day - 1].prefix(2))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 30, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                                    .foregroundStyle(on ? Theme.accent : .secondary)
                            }
                            .buttonStyle(.deckPlain)
                            .help(on ? "Runs on \(RoutineSchedule.weekdayNames[day - 1])" : "Doesn't run on \(RoutineSchedule.weekdayNames[day - 1])")
                        }
                    }
                }
            } else {
                Stepper(value: $routine.schedule.everyHours, in: 1...24) {
                    Text(routine.schedule.everyHours == 1 ? "Every hour" : "Every \(routine.schedule.everyHours) hours").monospacedDigit()
                }
                .font(.callout)
            }
            Text(routine.schedule.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggleDay(_ day: Int) {
        var days = Set(routine.schedule.weekdays.isEmpty ? Array(1...7) : routine.schedule.weekdays)
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
        // All days is "every day"; none at all would never run, so it's kept as is.
        guard !days.isEmpty else { return }
        routine.schedule.weekdays = days.count == 7 ? [] : days.sorted()
    }

    private func field<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            content()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: routine.folder)
        if panel.runModal() == .OK, let url = panel.url { routine.folder = url.path }
    }
}

// MARK: - A run

/// A run over the Routines screen.
struct RunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: RoutineRun

    var body: some View {
        RunView(run: run) {
            Button("Done") { dismiss() }.buttonStyle(.deck(.primary)).keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 820, minHeight: 640)
    }
}

/// One run: how it went, and the whole conversation (followed live while it runs); continue it
/// in the terminal to follow up.
struct RunView<Trailing: View>: View {
    @Environment(SessionStore.self) private var store
    let run: RoutineRun
    @ViewBuilder var trailing: () -> Trailing
    @State private var model = TranscriptModel()
    @State private var following = false
    @State private var error: String?

    /// The run as it is now (it updates while running).
    private var live: RoutineRun { store.routines.runs.first { $0.id == run.id && $0.routine == run.routine } ?? run }
    private var routine: Routine? { store.routines.routine(run.routine) }
    private var running: Bool { live.status == .running && !store.routines.isCutOff(live) }
    private var transcript: URL? { live.sessionId.flatMap { ClaudePaths.transcript(for: $0, cwd: routine?.folder) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RunStatusIcon(run: live)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RunRow.headline(live, cutOff: store.routines.isCutOff(live))).font(.headline).lineLimit(1)
                    Text(live.started.formatted(date: .abbreviated, time: .shortened) + (running ? " · running" : RunRow.details(live)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let routine, let id = live.sessionId, !running {
                    Button {
                        Task {
                            do {
                                try await Ghostty.resume(Session(sessionId: id, pid: nil, cwd: routine.folder, name: nil, title: nil,
                                                                 status: .ended, waitingFor: nil, updatedAt: Date(), transcriptURL: transcript))
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Label("Continue in Terminal", systemImage: "apple.terminal")
                    }
                    .buttonStyle(.deck())
                    .help("Resume this conversation in Ghostty to follow up")
                }
                trailing()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if following {
                TranscriptView(model: model, cwd: routine?.folder ?? "", status: running ? .busy : .ended, statusSince: live.started)
            } else {
                ScrollView {
                    HStack(spacing: 8) {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? "Starting Claude…" : live.result ?? "No conversation was recorded.")
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .background(Theme.surface)
        // The conversation's file appears once Claude starts writing; follow it from then.
        .task(id: run.id) {
            while !following && !Task.isCancelled {
                if let url = transcript {
                    model.start(url: url)
                    following = true
                } else if !running {
                    return
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .onDisappear { model.stop() }
        .alert("Couldn't open the terminal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

// MARK: - In the main window

/// A routine opened from the sidebar: what it is, its runs, and the chosen run's conversation.
struct RoutineDetailView: View {
    @Environment(SessionStore.self) private var store
    let routineId: String
    @State private var selectedRun: String?
    @State private var editing: Routine?

    private var routines: RoutineStore { store.routines }
    private var routine: Routine? { routines.routine(routineId) }
    private var runs: [RoutineRun] { routines.runs(of: routineId) }

    var body: some View {
        if let routine {
            VStack(spacing: 0) {
                header(routine)
                Divider()
                if runs.isEmpty {
                    ContentUnavailableView {
                        Label("No runs yet", systemImage: "alarm")
                    } description: {
                        Text(routine.enabled ? "Next run: \(RoutineCard.when(routine.schedule.next(after: Date()), now: Date())). Or run it now."
                                             : "It's paused. Switch it on, or run it now.")
                    }
                } else {
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(runs) { run in
                                    RunRow(run: run, unread: routines.isUnread(run), cutOff: routines.isCutOff(run)) { selectedRun = run.id }
                                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                            .fill(run.id == shownRun?.id ? Theme.accent.opacity(0.14) : .clear))
                                }
                            }
                            .padding(8)
                        }
                        .frame(width: 280)
                        Divider()
                        if let run = shownRun {
                            RunView(run: run) { EmptyView() }.id(run.id)
                        }
                    }
                }
            }
            .navigationTitle(routine.name)
            .navigationSubtitle("Routine · \(routine.schedule.summary)")
            .background(Theme.surface)
            .onAppear { routines.markSeen(routineId) }
            .onChange(of: routines.unread(of: routineId)) { routines.markSeen(routineId) }
            .sheet(item: $editing) { r in
                RoutineEditor(routine: r, isNew: false, onSave: { routines.save($0) },
                              onDelete: { routines.delete(r); store.selectedId = nil })
            }
        } else {
            ContentUnavailableView("Routine not found", systemImage: "alarm")
        }
    }

    /// The run picked in the list, or the newest.
    private var shownRun: RoutineRun? { runs.first { $0.id == selectedRun } ?? runs.first }

    private func header(_ routine: Routine) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { routine.enabled }, set: { routines.setEnabled(routine, $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(routine.enabled ? "On: runs on schedule. Switch off to pause." : "Paused. Switch on to run on schedule.")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(routine.schedule.summary) · \(Theme.shortPath(routine.folder)) · \(RoutineEditor.accessName(routine.access))")
                    .font(.callout).lineLimit(1)
                Text(routine.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(routine.prompt)
            }
            Spacer()
            Button { routines.runNow(routine) } label: { Label("Run Now", systemImage: "play.fill") }
                .buttonStyle(.deck())
                .disabled(runs.first.map { $0.status == .running && !routines.isCutOff($0) } ?? false)
                .help("Run it once now, in the background")
            Button("Edit…") { editing = routine }.buttonStyle(.deck())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// A routine in the sidebar: its state, name, when it runs, and new runs.
struct RoutineSidebarRow: View {
    @Environment(SessionStore.self) private var store
    let routine: Routine

    private var last: RoutineRun? { store.routines.runs(of: routine.id).first }
    private var unread: Int { store.routines.unread(of: routine.id) }

    var body: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 12)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14))
                if let last, last.status == .running, !store.routines.isCutOff(last) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: "alarm").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(routine.name).font(.body.weight(unread > 0 ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent))
                            .help("\(unread) new \(unread == 1 ? "run" : "runs")")
                    } else if let last {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text(Theme.ago(last.started, now: ctx.date)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(routine.enabled ? routine.schedule.summary : "Paused · \(routine.schedule.summary)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .opacity(routine.enabled ? 1 : 0.7)
        .help(last.map { RunRow.headline($0, cutOff: store.routines.isCutOff($0)) } ?? "No runs yet")
    }

    /// Green after a good run, red after a failed one, grey before any.
    private var tint: Color {
        switch last?.status {
        case .succeeded: Theme.success
        case .failed, .timedOut: Theme.danger
        case .running: Theme.accent
        case nil: .secondary
        }
    }
}
