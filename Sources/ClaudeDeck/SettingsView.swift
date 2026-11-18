import SwiftUI

/// Claude Deck's Settings window (⌘,).
struct SettingsView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Tell the coordinator what changes in the fleet", isOn: $store.fleetFeedOn)
                Text("When a session finishes, waits on you, gets stuck, restarts or ends, Deck types one line into the coordinator, such as “Fleet: api finished · web waiting on you (Bash)”. Only changes, at most every 2 minutes, and only while the coordinator is at its prompt. Muted sessions are left out.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: $store.stuckMinutes, in: 1...120) {
                    LabeledContent("Call a session stuck after", value: "\(store.stuckMinutes) min")
                }
                Text("A working session that writes nothing for this long, with no background command running, gets an orange Stuck badge in the sidebar.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Coordinator")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
