import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    let showOnboarding: () -> Void

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Screenme at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Toggle("Copy every capture to the clipboard", isOn: $state.copyAfterCapture)
                LabeledContent("Save to") {
                    HStack {
                        Text(state.saveDirectory.path(percentEncoded: false)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Button("Change…") { state.chooseSaveDirectory() }
                    }
                }
            }
            Section("Shortcuts") {
                ShortcutRow(keys: "⌘ ⇧ 1", label: "Capture area or window", ok: state.shortcutsRegistered)
                ShortcutRow(keys: "⌘ ⇧ 2", label: "Start or stop recording", ok: state.shortcutsRegistered)
                if !state.shortcutsRegistered {
                    Button("Fix shortcuts…", action: showOnboarding)
                }
            }
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    if state.screenRecordingGranted {
                        StatusBadge(ok: true, text: "On")
                    } else {
                        Button("Turn on…", action: showOnboarding)
                    }
                }
            }
            Section {
                Button("Run setup again", action: showOnboarding)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 480)
        .padding(.top, 20)
        .onReceive(poll) { _ in state.refresh() }
    }
}
