import Observation
import SwiftUI

/// Plan usage limits, from `claude -p "/usage"` (handled by Claude Code locally, no model call).
@MainActor
@Observable
final class UsageModel {
    private(set) var usage: PlanUsage?
    private(set) var fetchedAt: Date?
    private(set) var loading = false
    private(set) var error: String?

    private var timer: Timer?

    /// Loads now and every 5 minutes, so the menu bar and sidebar stay current.
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    func refresh(force: Bool = false) {
        if loading { return }
        if !force, let at = fetchedAt, Date().timeIntervalSince(at) < 60 { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = ClaudeRunner.run(["-p", "/usage"], in: NSHomeDirectory(), timeout: 60)
            await MainActor.run {
                self.loading = false
                switch result {
                case .success(let out):
                    let parsed = PlanUsage.parse(out)
                    if parsed.limits.isEmpty {
                        self.error = out.isEmpty ? "No output from claude /usage" : out.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.usage = parsed
                        self.error = nil
                    }
                    self.fetchedAt = Date()
                case .failure(let e):
                    self.error = e.message
                }
            }
        }
    }
}

struct UsageSheet: View {
    @Environment(UsageModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plan usage").font(.title3.weight(.semibold))
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(model.fetchedAt.map { "Updated \(Theme.ago($0)) ago. Refresh" } ?? "Refresh")
                }
            }
            if let usage = model.usage {
                if !usage.summary.isEmpty {
                    Text(usage.summary).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(usage.limits) { UsageBar(limit: $0) }
                if !usage.details.isEmpty {
                    Divider()
                    ScrollView {
                        Text(usage.details.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Text("Checking your plan…").foregroundStyle(.secondary)
            }
            HStack {
                Text(verbatim: "From claude /usage. Checking doesn't use any of your limits.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.deck(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .tint(Theme.accent)
        .onAppear { model.refresh() }
    }
}

struct UsageBar: View {
    let limit: PlanUsage.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limit.label).font(.callout.weight(.medium))
                Spacer()
                Text("\(limit.percent)%").font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(UsageMeter.color(limit.percent)).frame(width: max(4, geo.size.width * CGFloat(min(limit.percent, 100)) / 100))
                }
            }
            .frame(height: 7)
            if !limit.resets.isEmpty {
                Text("Resets \(limit.resets)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact plan usage (small bars per limit) for the sidebar footer and menu bar panel.
struct UsageStrip: View {
    @Environment(UsageModel.self) private var model
    let open: () -> Void

    var body: some View {
        if let usage = model.usage, !usage.limits.isEmpty {
            Button(action: open) {
                HStack(spacing: 12) {
                    ForEach(usage.limits) { limit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(limit.shortLabel).foregroundStyle(.secondary)
                                Spacer(minLength: 2)
                                Text("\(limit.percent)%").monospacedDigit().foregroundStyle(.primary)
                            }
                            .font(.caption2.weight(.medium))
                            UsageMeter(percent: limit.percent).frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Plan usage (⇧⌘U)")
        }
    }
}

struct UsageMeter: View {
    let percent: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(UsageMeter.color(percent)).frame(width: max(3, geo.size.width * CGFloat(min(percent, 100)) / 100))
            }
        }
    }

    static func color(_ percent: Int) -> Color {
        percent >= 80 ? Theme.danger : percent >= 50 ? Theme.waiting : Theme.success
    }
}
