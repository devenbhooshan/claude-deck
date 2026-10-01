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
            } else {
                EmptyDetail(running: store.live.count, waiting: waiting.count)
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { switcherOverlay }
        .animation(.easeOut(duration: 0.12), value: store.showSwitcher)
        .modifier(Dialogs(newName: $newName))
        // The sidebar's skills and MCP servers follow the selected session's project.
        .onChange(of: store.selectedId, initial: true) { toolbox.focus(cwd: store.session(store.selectedId)?.cwd) }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $store.selectedId) {
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
                    .tag(s.id)
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
            if !store.recent.isEmpty {
                Section {
                    ForEach(store.recent) { s in
                        SessionRow(session: s).tag(s.id).contextMenu { rowMenu(s) }
                    }
                } header: {
                    SectionHeader(title: "Recent", count: nil, tint: nil)
                }
            }
            ToolboxSections()
        }
        .listStyle(.sidebar)
        .toolbar {
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
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
    }

    @ViewBuilder
    private var switcherOverlay: some View {
        if store.showSwitcher {
            ZStack(alignment: .top) {
                Color.black.opacity(0.08).ignoresSafeArea()
                    .onTapGesture { store.showSwitcher = false }
                SessionSwitcher().padding(.top, 70)
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
            .alert("Couldn't reach the terminal", isPresented: failed) {
                Button("OK") { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
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
        Button("Rename…") { store.renameTarget = s }
        if s.isLive {
            Button("Open Terminal") { store.openTerminal(s) }
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
    @Environment(SessionStore.self) private var store
    let session: Session
    var number: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SessionRow(session: session, number: number)
            if let tool = session.pendingTool {
                HStack(spacing: 6) {
                    Image(systemName: ToolStyle.symbol(tool.name)).font(.caption2)
                    Text(tool.summary.replacingOccurrences(of: session.cwd + "/", with: ""))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, SessionRow.titleInset)
            }
            ApprovalButtons(session: session)
                .padding(.leading, SessionRow.titleInset)
        }
        .padding(.bottom, 4)
        .listRowBackground(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.waiting.opacity(0.08)).padding(.horizontal, 10))
    }
}

/// ⌘K palette: type to filter, arrows to move, return to open.
struct SessionSwitcher: View {
    @Environment(SessionStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.ordered
        guard !q.isEmpty else { return Array(all.prefix(12)) }
        return Array(all.filter {
            "\($0.displayTitle) \($0.projectName) \($0.cwd)".lowercased().contains(q)
        }.prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(open)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { store.showSwitcher = false; return .handled }
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 10) {
                            StatusIcon(status: s.status)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.displayTitle).lineLimit(1)
                                Text(s.status == .waiting ? "\(s.projectName) · Needs you" : s.projectName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let n = store.live.firstIndex(where: { $0.id == s.id }), n < 9 {
                                Text("⌘\(n + 1)").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(i == highlighted ? Theme.accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = i; open() }
                    }
                    if matches.isEmpty {
                        Text("No matching sessions").foregroundStyle(.tertiary).padding(20)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func move(_ d: Int) {
        guard !matches.isEmpty else { return }
        highlighted = (highlighted + d + matches.count) % matches.count
    }

    private func open() {
        guard matches.indices.contains(highlighted) else { return }
        store.selectedId = matches[highlighted].id
        store.showSwitcher = false
        query = ""
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

struct SessionRow: View {
    let session: Session
    /// The session's fixed number (⌘1–9 opens it), shown for running sessions.
    var number: Int? = nil

    /// Space before the title, for indenting content under it.
    static let titleInset: CGFloat = 50

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
                        .font(.body.weight(session.status == .waiting ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(Theme.ago(session.updatedAt, now: ctx.date))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if session.status == .waiting, let w = session.waitingFor {
            return "\(session.projectName) · \(w.prefix(1).uppercased() + w.dropFirst())"
        }
        return session.projectName
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
