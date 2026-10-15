import AppKit
import Carbon.HIToolbox
import SwiftUI
import UserNotifications

@main
struct ClaudeDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SessionStore()
    @State private var toolbox = ToolboxStore()
    @State private var usage = UsageModel()
    @State private var activity = ActivityStore.shared
    @AppStorage(DeckThemes.key) private var theme = DeckTheme.classic.rawValue

    init() { DeckThemes.load() }

    var body: some Scene {
        Window("Claude Deck", id: "main") {
            MainWindow()
                // A new theme rebuilds the window with its colours.
                .id(theme)
                .onChange(of: theme) { DeckThemes.apply(theme) }
                .environment(store)
                .environment(toolbox)
                .environment(usage)
                .environment(activity)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.store = store
                    store.start()
                    usage.start()
                    activity.start()
                    FloatingDock.shared.restore(store: store, usage: usage)
                }
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            SessionCommands(store: store, usage: usage, activity: activity)
            CommandGroup(after: .sidebar) {
                Picker("Theme", selection: $theme) {
                    ForEach(DeckTheme.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
            }
        }


        MenuBarExtra {
            MenuBarContent().environment(store).environment(usage).environment(activity).id(theme)
        } label: {
            Image(systemName: store.waitingCount > 0 ? "exclamationmark.bubble.fill" : "bubble.left.and.bubble.right")
            Text(menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}

extension ClaudeDeckApp {
    /// "2 · 35%": sessions waiting on you, then your current-session plan usage.
    var menuBarText: String {
        let pct = usage.usage?.session.map { "\($0.percent)%" }
        return [store.waitingCount > 0 ? "\(store.waitingCount)" : nil, pct].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Hosts ContentView and hands the store a way to re-open this window.
private struct MainWindow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear {
                store.openMainWindow = { openWindow(id: "main") }
                // For checking the UI from the command line.
                if CommandLine.arguments.contains("--activity-tab") { store.detailTab = .activity }
                if CommandLine.arguments.contains("--open-history") { store.showHistory = true }
            }
    }
}

struct SessionCommands: Commands {
    let store: SessionStore
    let usage: UsageModel
    @Bindable var activity: ActivityStore

    var body: some Commands {
        CommandMenu("Sessions") {
            Button("New Session…") { store.showNewSession = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Plan Usage…") { store.showUsage = true }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Show / Hide Floating Dock") { FloatingDock.shared.toggle(store: store, usage: usage) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Activity History…") { store.showHistory = true; store.bringToFront() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(store.detailTab == .activity ? "Show Conversation" : "Show Activity") {
                store.detailTab = store.detailTab == .activity ? .conversation : .activity
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(store.selectedId == nil)
            Toggle("AI Activity Summaries", isOn: $activity.aiSummaries)
            Button("Search & Jump…") { store.showSwitcher.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Next Session Needing You") { store.selectNextWaiting() }
                .keyboardShortcut("j", modifiers: .command)
            Divider()
            Button("Previous Session") { store.select(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Session") { store.select(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1..<10) { n in
                Button("Session \(n)") {
                    // The numbers shown next to running sessions.
                    if store.live.indices.contains(n - 1) { store.selectedId = store.live[n - 1].id }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
            Button("Allow Next Prompt  ⌥⌘↩") { store.respondToNext(allow: true) }
            Button("Deny Next Prompt  ⌥⌘⌫") { store.respondToNext(allow: false) }
            Divider()
            Button("Rename Session…") {
                if let s = store.session(store.selectedId) { store.renameTarget = s }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.selectedId == nil)
            Button("Restart Session") {
                if let s = store.session(store.selectedId), s.isLive, s.status == .idle { store.restart(s) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(store.session(store.selectedId).map { !$0.isLive || $0.status != .idle } ?? true || store.restarting != nil)
            Button("Stop Current Step") {
                if let s = store.session(store.selectedId), s.isLive, s.status == .busy { store.interrupt(s) }
            }
            .disabled(store.session(store.selectedId)?.status != .busy)
            Button("Open Terminal") {
                if let s = store.session(store.selectedId), s.isLive {
                    Task {
                        do { try await Ghostty.focus(s) } catch { store.lastError = error.localizedDescription }
                    }
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: SessionStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DeckThemes.apply(Palette.theme.rawValue)
        UNUserNotificationCenter.current().delegate = self
        Notifications.registerCategories()
        // ⇧⌘Space from anywhere: bring Deck forward with the session switcher open.
        GlobalHotKey.register(keyCode: kVK_Space, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.store?.bringToFront(switcher: true) }
        }
        // ⌥⌘↩ / ⌥⌘⌫ from anywhere: allow / deny the next permission prompt.
        // (⌥⌘↩ is Ghostty's zoom-split and ⌥⌘⎋ is Force Quit, so those are avoided.)
        GlobalHotKey.register(keyCode: kVK_Return, modifiers: cmdKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.store?.respondToNext(allow: true) }
        }
        GlobalHotKey.register(keyCode: kVK_Delete, modifiers: cmdKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.store?.respondToNext(allow: false) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { store?.bringToFront() } }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["sessionId"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let store else { return }
            switch action {
            case Notifications.allow, Notifications.deny:
                // Answer in place; don't pull you away from what you're doing. Only the exact
                // prompt the banner was about can be answered.
                let since = response.notification.request.content.userInfo["since"] as? Double
                if let s = store.live.first(where: { $0.id == id }) {
                    store.respond(s, key: action == Notifications.allow ? "enter" : "escape", expectedSince: since)
                }
            default:
                store.selectedId = id
                store.bringToFront()
            }
        }
    }
}

/// The menu bar panel, built from the same components as the main window.
struct MenuBarContent: View {
    @Environment(SessionStore.self) private var store
    @Environment(UsageModel.self) private var usage

    var body: some View {
        let waiting = store.live.filter { $0.status == .waiting }
        let others = store.live.filter { $0.status != .waiting }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Deck").font(.headline)
                Spacer()
                Button {
                    store.bringToFront(switcher: true)
                } label: {
                    Label("Jump to Session", systemImage: "magnifyingglass")
                }
                .buttonStyle(.deckBorderless)
                .labelStyle(.iconOnly)
                .help("Jump to a session (⇧⌘Space)")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            UsageStrip { store.showUsage = true; store.bringToFront() }
                .padding(.horizontal, 12).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !waiting.isEmpty {
                        header("Needs you", count: waiting.count)
                        ForEach(waiting) { s in
                            VStack(alignment: .leading, spacing: 6) {
                                row(s)
                                if let tool = s.pendingTool {
                                    Text("\(ToolStyle.displayName(tool.name)): \(tool.summary)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .padding(.leading, 32)
                                }
                                ApprovalButtons(session: s).padding(.leading, 32)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                .fill(Theme.waiting.opacity(0.08)))
                        }
                    }
                    header("Running", count: others.count)
                    if store.live.isEmpty {
                        Text("No running sessions").font(.callout).foregroundStyle(.tertiary).padding(8)
                    }
                    ForEach(others) { s in
                        Button { open(s) } label: { row(s).padding(8).contentShape(Rectangle()) }
                            .buttonStyle(MenuRowStyle())
                    }
                }
                .padding(.horizontal, 8)
            }
            // Size to the content (up to 460pt); otherwise the scroll area collapses to nothing here.
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.top, 6)
            HStack {
                Button("Plan Usage…") { store.showUsage = true; store.bringToFront() }
                Button("Floating Dock") { FloatingDock.shared.toggle(store: store, usage: usage) }
                    .help("An always-on-top panel to Allow / Deny from any app (⇧⌘D)")
                Menu("Theme") {
                    ForEach(DeckTheme.allCases, id: \.rawValue) { t in
                        Button { UserDefaults.standard.set(t.rawValue, forKey: DeckThemes.key) } label: {
                            Text(t == Palette.theme ? "✓ \(t.name)" : t.name)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
        Button("Open Claude Deck") { store.bringToFront() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.deckBorderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 360)
        .tint(Theme.accent)
    }

    private func header(_ title: String, count: Int) -> some View {
        Text(count > 0 ? "\(title) · \(count)" : title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ s: Session) -> some View {
        HStack(spacing: 10) {
            StatusIcon(status: s.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle).lineLimit(1)
                Text(s.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func open(_ s: Session) {
        store.selectedId = s.id
        store.bringToFront()
    }
}

/// Highlight on hover, like a native menu item.
private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
            .pointingHand()
    }
}

/// Reading, saving and applying the chosen theme.
enum DeckThemes {
    static let key = "theme"

    /// The saved theme, before any view is drawn.
    static func load() {
        Palette.theme = UserDefaults.standard.string(forKey: key).flatMap(DeckTheme.init(rawValue:)) ?? .classic
    }

    @MainActor static func apply(_ raw: String) {
        Palette.theme = DeckTheme(rawValue: raw) ?? .classic
        NSApp.appearance = Palette.theme.appearance.flatMap(NSAppearance.init(named:))
        FloatingDock.shared.reload()
    }
}
