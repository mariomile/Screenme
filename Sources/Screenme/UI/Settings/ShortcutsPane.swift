import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    var body: some View {
        Form {
            Section {
                MacOSShortcutsBlock()
            } header: {
                Text("macOS screenshot shortcuts")
            } footer: {
                Text("Screenme replaces the built-in screenshot shortcuts by turning them off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots. Restore puts them back.")
            }

            if !shortcuts.system.rivals.isEmpty {
                Section("Other screenshot apps") { RivalAppsBlock() }
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(action: action)
                }
            } header: {
                Text("Screenme shortcuts")
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels, Delete clears.")
                    Spacer()
                    Button("Reset to defaults") { ShortcutStore.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { shortcuts.refresh() }
    }
}
