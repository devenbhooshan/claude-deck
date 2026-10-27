import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @Environment(ToolboxStore.self) private var toolbox
    @State private var newName = ""
    @State private var confirmHook = false

    private var waiting: [Session] { store.live.filter { $0.status == .waiting } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let s = store.session(store.selectedId) {
                SessionDetailView(session: s).id(s.id)
            } else if let id = store.selectedId, id.hasPrefix("routine:") {
                RoutineDetailView(routineId: String(id.dropFirst(8))).id(id)
            } else {
                EmptyDetail(running: store.live.count, waiting: waiting.count)
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { switcherOverlay }
        .overlay { historyOverlay }
        .animation(.easeOut(duration: 0.12), value: store.showSwitcher)
        .animation(.easeOut(duration: 0.15), value: store.showHistory)
        .modifier(Dialogs(newName: $newName))
        // The "/" menu's commands and skills follow the selected session's project.
        .onChange(of: store.selectedId, initial: true) { toolbox.focus(cwd: store.session(store.selectedId)?.cwd) }
    }

    private var sidebar: some View {
        @Bindable var store = store
        // Selection is drawn by Deck, not the system list: the system highlight switches from the
        // accent colour to grey when focus moves to the message box, which made the row flicker.
        return List {
            // One fixed list: a session keeps its place and number (⌘1–9) whatever its status.
            // Sessions waiting on you stay put and show Allow / Deny in place.
            Section {
                if store.live.isEmpty {
                    Text("No running sessions").foregroundStyle(.tertiary).font(.callout)
                }
                ForEach(Array(store.live.enumerated()), id: \.element.id) { i, s in
                    Group {
                        if s.status == .waiting {
                            ApprovalRow(session: s, number: i + 1)
                        } else {
                            SessionRow(session: s, number: i + 1)
                        }
                    }
                    .modifier(SelectableRow(id: s.id))
                    .contextMenu { rowMenu(s) }
                }
            } header: {
                HStack(spacing: 6) {
                    SectionHeader(title: "Running", count: store.live.count, tint: nil)
                    if !waiting.isEmpty {
                        Text("\(waiting.count) need\(waiting.count == 1 ? "s" : "") you")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.waiting.opacity(0.18)))
                            .foregroundStyle(Theme.waiting)
                    }
                }
            }
            if !store.routines.routines.isEmpty {
                Section {
                    ForEach(store.routines.routines) { r in
                        RoutineSidebarRow(routine: r)
                            .modifier(SelectableRow(id: "routine:" + r.id))
                            .contextMenu {
                                Button("Run Now") { store.routines.runNow(r) }
                                Toggle("On", isOn: Binding(get: { r.enabled }, set: { store.routines.setEnabled(r, $0) }))
                                Divider()
                                Button("Manage Routines…") { store.showRoutines = true }
                            }
                    }
                } header: {
                    HStack {
                        SectionHeader(title: "Routines", count: nil, tint: nil)
                        Spacer()
                        Button { store.showRoutines = true } label: { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                            .buttonStyle(.deckBorderless)
                            .help("New or manage routines (⇧⌘R)")
                    }
                }
            }
            if !store.recent.isEmpty {
                Section {
                    ForEach(store.recent) { s in
                        SessionRow(session: s).modifier(SelectableRow(id: s.id)).contextMenu { rowMenu(s) }
                    }
                } header: {
                    SectionHeader(title: "Recent", count: nil, tint: nil)
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(ThemedSidebar())
        .toolbar {
            ToolbarItem {
                Button {
                    store.showSwitcher = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Jump to a session, search everything, or ask a question (⌘K)")
            }
            ToolbarItem {
                Button {
                    store.showHistory = true
                } label: {
                    Label("Activity History", systemImage: "clock.arrow.circlepath")
                }
                .help("Every PR, ticket and screenshot your sessions touched (⇧⌘H)")
            }
            ToolbarItem {
                Button {
                    store.showPolicies = true
                } label: {
                    Label("Policies", systemImage: "checkmark.shield")
                }
                .help("Rules checked before every tool call in every session (⇧⌘P)")
            }
            ToolbarItem {
                Button {
                    store.showRoutines = true
                } label: {
                    Label("Routines", systemImage: "alarm")
                        .overlay(alignment: .topTrailing) {
                            if store.routines.unread > 0 {
                                Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 3, y: -2)
                            }
                        }
                }
                .help(store.routines.unread > 0
                      ? "Routines: \(store.routines.unread) new \(store.routines.unread == 1 ? "run" : "runs") (⇧⌘R)"
                      : "Prompts Claude runs on a schedule on this Mac (⇧⌘R)")
            }
            ToolbarItem {
                Button {
                    store.showNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("Start Claude in a folder (⌘N)")
            }
        }
        .sheet(isPresented: $store.showNewSession) { NewSessionSheet() }
        .sheet(isPresented: $store.showUsage) { UsageSheet() }
        .sheet(isPresented: $store.showPolicies) { PoliciesSheet() }
        .sheet(isPresented: $store.showRoutines) { RoutinesSheet() }
        .sheet(item: $store.viewing) { file in
            if FileLinks.kind(of: file.url) == .markdown { MarkdownEditor(url: file.url) } else { FileViewer(url: file.url) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if !store.hookInstalled {
                    HookSetupCard { confirmHook = true }
                }
                UsageStrip { store.showUsage = true }
            }
            .padding(10)
        }
        .confirmationDialog("Show what each permission prompt is asking?", isPresented: $confirmHook) {
            Button("Add Hook to ~/.claude/settings.json") { store.installHook() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deck adds a small PermissionRequest hook that saves each request (tool and command) to a file Deck reads. It never answers prompts itself. Your current settings are backed up to settings.json.claudedeck-backup first, and running sessions pick it up without a restart.")
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 480)
    }

    @ViewBuilder
    private var historyOverlay: some View {
        if store.showHistory {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { store.showHistory = false }
                    HistoryPanel()
                        .frame(width: min(980, geo.size.width - 60), height: max(320, geo.size.height - 70))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var switcherOverlay: some View {
        if store.showSwitcher {
            ZStack(alignment: .top) {
                Color.black.opacity(0.08).ignoresSafeArea()
                    .onTapGesture { store.showSwitcher = false }
                CommandPalette().padding(.top, 60)
            }
            .transition(.opacity)
        }
    }
}

/// The rename prompt and error alert.
private struct Dialogs: ViewModifier {
    @Environment(SessionStore.self) private var store
    @Binding var newName: String

    func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: renaming) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let s = store.renameTarget { store.rename(s, to: newName) }
                    store.renameTarget = nil
                }
                Button("Cancel", role: .cancel) { store.renameTarget = nil }
            } message: {
                Text(store.renameTarget?.isLive == true
                     ? "Sends /rename to the session, so the name also shows in Claude Code and /resume."
                     : "Saves the name to the session's transcript, so it also shows in /resume.")
            }
            .onChange(of: store.renameTarget?.id) {
                newName = store.renameTarget?.displayTitle ?? ""
            }
            .alert("End this session?", isPresented: confirmingEnd) {
                Button("End Session", role: .destructive) {
                    if let s = store.endTarget { store.end(s) }
                    store.endTarget = nil
                }
                Button("Cancel", role: .cancel) { store.endTarget = nil }
            } message: {
                Text(store.endTarget?.status == .waiting
                     ? "Claude is waiting on a prompt. Ending dismisses it, quits Claude and closes its terminal. You can resume it later."
                     : store.endTarget?.status == .background
                     ? "A background task Claude started is still running. Ending stops it, quits Claude and closes its terminal. You can resume the session later."
                     : "Claude is still working. Ending stops this step, quits Claude and closes its terminal. You can resume it later.")
            }
            .alert("Couldn't reach the terminal", isPresented: failed) {
                Button("OK") { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
    }

    private var confirmingEnd: Binding<Bool> {
        Binding(get: { store.endTarget != nil }, set: { if !$0 { store.endTarget = nil } })
    }

    private var renaming: Binding<Bool> {
        Binding(get: { store.renameTarget != nil }, set: { if !$0 { store.renameTarget = nil } })
    }

    private var failed: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
    }
}

extension ContentView {
    @ViewBuilder
    func rowMenu(_ s: Session) -> some View {
        if s.status == .waiting && PromptGuard.canAnswerHere(s) && !store.isAnswered(s) {
            Button("Allow") { store.respond(s, key: "enter") }
            Button("Always Allow (option 2)") { store.respond(s, key: "2") }
            Button("Deny") { store.respond(s, key: "escape") }
            Divider()
        }
        Button("Rename…") { store.renameTarget = s }
        if s.isLive {
            Toggle("Remote Control", isOn: Binding(get: { store.isRemote(s) }, set: { store.setRemote(s, on: $0) }))
            if let url = s.remoteURL {
                Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
            }
            Button("Open Terminal") { store.openTerminal(s) }
            Button("Restart Session") { store.restart(s) }
                .disabled(s.status != .idle || store.restarting != nil)
            Button("End Session") { store.requestEnd(s) }
                .disabled(store.ending.contains(s.sessionId))
        }
        Divider()
        Button("Copy Session ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.sessionId, forType: .string)
        }
    }
}

private struct HookSetupCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("See what you're approving", systemImage: "eye")
                .font(.callout.weight(.semibold))
            Text("Show the exact command behind each permission prompt, here and in notifications.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up…", action: action).buttonStyle(.deck(.secondary, size: .small))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.accent.opacity(0.1)))
    }
}

/// A waiting session in the sidebar, answerable without opening it.
struct ApprovalRow: View {
    let session: Session
    var number: Int? = nil

    /// A waiting session, the same size as any other row: the request in the subtitle and
    /// small Allow / Deny buttons where the time usually is.
    var body: some View {
        SessionRow(session: session, number: number) { QuickApproval(session: session) }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int?
    let tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill((tint ?? .secondary).opacity(0.18)))
                    .foregroundStyle(tint ?? .secondary)
            }
        }
    }
}

struct SessionRow<Accessory: View>: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(SessionStore.self) private var store
    let session: Session
    /// The session's fixed number (⌘1–9 opens it), shown for running sessions.
    var number: Int? = nil
    /// Shown instead of the time (e.g. Allow / Deny for a waiting session).
    var accessory: Accessory?

    init(session: Session, number: Int? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.session = session
        self.number = number
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(number.map(String.init) ?? "")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .trailing)
            StatusIcon(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayTitle)
                        .font(.body.weight(session.status == .waiting || unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !session.background.isEmpty && accessory == nil {
                        Image(systemName: session.onlyServers ? "server.rack" : "terminal")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help(session.background.map(\.command).joined(separator: "\n") + " running in the background")
                    }
                    if session.isLive && store.isRemote(session) && accessory == nil {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .help("Connected with Remote Control")
                    }
                    if unread > 0 && accessory == nil {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent))
                            .help("\(unread) new \(unread == 1 ? "reply" : "replies") from Claude")
                    }
                    if let accessory {
                        accessory
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text(Theme.ago(session.updatedAt, now: ctx.date))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        // Running sessions get their task named again when you send them a new message.
        .task(id: session.isLive ? activity.lastAsk(session.sessionId) : nil) {
            if session.isLive { activity.nameTask(session.sessionId) }
        }
    }

    private var unread: Int { store.unread(session) }

    private var subtitle: String {
        // What it's on (ticket · PR) when known, then the project. The orange hand and ✓ / ✕
        // already say it's waiting (hover ✓ for the request).
        // The task it's on (named from your latest messages), else its ticket and PR, then the project.
        if let task = activity.task(for: session.sessionId) { return "\(task) · \(session.projectName)" }
        guard let work = activity.current(for: session.sessionId) else { return session.projectName }
        let refs = [work.ticket, work.pr?.ref].compactMap { $0 }
        return (refs + [session.projectName]).joined(separator: " · ")
    }
}

private struct EmptyDetail: View {
    let running: Int
    let waiting: Int

    static let shortcuts: [(String, String)] = [
        ("⌘K", "Jump to a session"),
        ("⇧⌘Space", "Open Deck's switcher from any app"),
        ("⌥⌘↩", "Allow the next prompt (works in any app)"),
        ("⌥⌘⌫", "Deny the next prompt (works in any app)"),
        ("⌘J", "Next session that needs you"),
        ("⌘1 – ⌘9", "Go to session 1–9"),
        ("⌥⌘↑ / ↓", "Previous / next session"),
        ("⌘R", "Rename session"),
        ("⇧⌘T", "Open session's terminal"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Claude Deck").font(.title2.weight(.semibold))
            Text(waiting > 0
                 ? "\(waiting) of \(running) sessions need you. Pick one from the sidebar."
                 : "\(running) sessions running. Pick one from the sidebar.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(Self.shortcuts, id: \.0) { keys, action in
                    GridRow {
                        Text(keys)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color.primary.opacity(0.07)))
                            .gridColumnAlignment(.trailing)
                        Text(action).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Claude Deck")
    }
}

extension SessionRow where Accessory == EmptyView {
    init(session: Session, number: Int? = nil) {
        self.session = session
        self.number = number
        self.accessory = nil
    }
}

/// Deck's own selection: click to open, and one steady highlight for the open session.
struct SelectableRow: ViewModifier {
    @Environment(SessionStore.self) private var store
    let id: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        let selected = store.selectedId == id
        content
            .contentShape(Rectangle())
            .onTapGesture { store.selectedId = id }
            .onHover { hovering = $0 }
            .pointingHand()
            .listRowBackground(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : Color.clear)
                    .padding(.horizontal, 10)
            )
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
