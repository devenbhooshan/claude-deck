import AppKit
import SwiftUI

/// A session's PR, checks and deploy state in one chip: small in the sidebar, with words and a
/// menu of ship actions in the session's bar. Clicking it opens the PR.
struct CIChip: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    /// The sidebar's: number and icons only.
    var compact = false

    var body: some View {
        if session.isLive, let status = store.ci.status(for: session), !status.isEmpty {
            if compact {
                chip(status)
            } else {
                HStack(spacing: 2) {
                    chip(status)
                    Menu { CIMenuItems(session: session) } label: {
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Fix failing checks, push, merge when green, or set this repo's deploy-status command")
                }
            }
        }
    }

    private func chip(_ status: CIStatus) -> some View {
        Button {
            if let url = status.pr?.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                if let pr = status.pr {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.pull").font(.caption2.weight(.semibold))
                        Text("#\(pr.number)").font(.caption2.monospacedDigit().weight(.semibold))
                    }
                    .foregroundStyle(pr.state == .merged ? Color.purple : .secondary)
                    if pr.state == .merged || pr.state == .closed {
                        if !compact { Text(pr.state == .merged ? "Merged" : "Closed").font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
                    } else {
                        CIStateIcon(state: status.checks.state)
                        if !compact { Text(checksLabel(status.checks)).font(.caption2.weight(.medium)).foregroundStyle(tint(status.checks.state)) }
                    }
                }
                if let deploy = status.deploy {
                    if status.pr != nil && !compact { Divider().frame(height: 10) }
                    Image(systemName: deploy.deployed ? "shippingbox.fill" : "shippingbox")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(deploy.deployed ? Theme.success : Theme.danger)
                    if !compact {
                        Text(deploy.deployed ? "Deployed" : "Not deployed").font(.caption2.weight(.medium))
                            .foregroundStyle(deploy.deployed ? Theme.success : Theme.danger)
                    }
                }
            }
            .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 1 : 4)
            .background(Capsule().fill(tint(status.checks.state).opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint(status.checks.state).opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.deckPlain)
        .help(help(status))
    }

    private func checksLabel(_ checks: CIChecks) -> String {
        switch checks.state {
        case .none: "No checks"
        case .pending: "Checks running"
        case .passing: "Checks passed"
        case .failing: checks.failing.count == 1 ? "1 check failed" : "\(checks.failing.count) checks failed"
        }
    }

    private func tint(_ state: CIState) -> Color {
        switch state {
        case .none: .secondary
        case .pending: Theme.busy
        case .passing: Theme.success
        case .failing: Theme.danger
        }
    }

    private func help(_ status: CIStatus) -> String {
        var lines: [String] = []
        if let pr = status.pr {
            lines.append("PR #\(pr.number): \(checksLabel(status.checks).lowercased())")
            if !status.checks.failing.isEmpty { lines.append("Failing: " + status.checks.failing.joined(separator: ", ")) }
        }
        if let d = status.deploy {
            lines.append((d.deployed ? "Deployed" : "Not deployed") + (d.detail.map { ": \($0)" } ?? ""))
        }
        let ago = Theme.ago(status.checkedAt)
        lines.append((ago == "now" ? "Checked just now" : "Checked \(ago) ago") + (status.pr?.url != nil ? ". Click to open the PR." : ""))
        return lines.joined(separator: "\n")
    }
}

/// Pending (spinner), passed (green tick) or failed (red cross).
struct CIStateIcon: View {
    let state: CIState

    var body: some View {
        switch state {
        case .pending: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
        case .passing: Image(systemName: "checkmark.circle.fill").font(.caption2.weight(.bold)).foregroundStyle(Theme.success)
        case .failing: Image(systemName: "xmark.circle.fill").font(.caption2.weight(.bold)).foregroundStyle(Theme.danger)
        case .none: Image(systemName: "circle.dashed").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The ship actions (each puts a message in the session's box for you to edit and send), plus
/// Check Now and the repo's deploy-status command. Used in the chip's menu and the row's.
struct CIMenuItems: View {
    @Environment(SessionStore.self) private var store
    let session: Session

    var body: some View {
        let status = store.ci.status(for: session)
        let open = status?.pr.map { $0.state == .open || $0.state == .draft } ?? false
        if let pr = status?.pr, let url = pr.url.flatMap(URL.init(string:)) {
            Button("Open PR #\(pr.number)") { NSWorkspace.shared.open(url) }
            Divider()
        }
        ForEach(CIAction.allCases, id: \.self) { action in
            Button(action.title) { store.draftMessage(action.message(for: status), in: session) }
                .disabled(action == .fixChecks ? status?.checks.state != .failing : action == .mergeWhenGreen ? !open : false)
                .help("Puts a message in this session's box for you to edit and send")
        }
        Divider()
        Button("Check CI Now") { store.ci.checkNow(session) }
        Button("Deploy Status Command…") { store.deployCommandTarget = session }
    }
}

/// A CI change in Needs You: what flipped, and the actions that follow from it.
struct CIAlertActions: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    let alert: CIAlert

    var body: some View {
        HStack(spacing: 8) {
            CIStateIcon(state: alert.status.checks.state)
            Text(alert.summary).frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 8) {
            switch alert.flip {
            case .wentRed:
                actionButton(.fixChecks, primary: true)
            case .wentGreen:
                actionButton(.mergeWhenGreen, primary: true)
            case .deployed, .deployFailed:
                EmptyView()
            }
            if let url = alert.status.pr?.url.flatMap(URL.init(string:)) {
                Button("Open PR") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.deck(.secondary))
            }
            Spacer()
        }
    }

    private func actionButton(_ action: CIAction, primary: Bool) -> some View {
        Button(action.title) {
            store.draftMessage(action.message(for: alert.status), in: session)
            store.dismiss(.ci(session, alert))
        }
        .buttonStyle(.deck(primary ? .primary : .secondary))
        .help("Open \(session.displayTitle) with this in its message box, to edit and send")
    }
}

/// Editing a repo's deploy-status command: exit 0 means deployed.
struct DeployCommandDialog: ViewModifier {
    @Environment(SessionStore.self) private var store
    @State private var command = ""

    func body(content: Content) -> some View {
        content
            .alert("Deploy Status Command", isPresented: Binding(get: { store.deployCommandTarget != nil },
                                                                  set: { if !$0 { store.deployCommandTarget = nil } })) {
                TextField("e.g. ./scripts/is-deployed.sh", text: $command)
                Button("Save") {
                    if let s = store.deployCommandTarget { store.ci.setDeployCommand(command, for: s) }
                    store.deployCommandTarget = nil
                }
                Button("Cancel", role: .cancel) { store.deployCommandTarget = nil }
            } message: {
                Text("Runs in \(store.deployCommandTarget.map { Theme.shortPath(CIStatus.repoRoot(for: $0.cwd) ?? $0.cwd) } ?? "the repo") with the PR's checks. Exit 0 means deployed; its last line of output is shown. Leave it empty to turn it off.")
            }
            .onChange(of: store.deployCommandTarget?.id) {
                command = store.deployCommandTarget.map { store.ci.deployCommand(for: $0) ?? "" } ?? ""
            }
    }
}
