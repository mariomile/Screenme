import SwiftUI

struct PermissionsPane: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { PermissionRow(permission: $0) }
            } footer: {
                Text("Permissions are managed by macOS. Screenme only asks for what a feature needs.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Relaunch Screenme")
                        Text(permissions.isGranted(.screenRecording)
                             ? "Use this if captures still fail after changing a permission."
                             : "After turning Screen Recording on, relaunch so macOS applies it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if permissions.isGranted(.screenRecording) {
                        Button("Relaunch") { state.relaunch() }
                    } else {
                        Button("Relaunch") { state.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .polling(every: 1) { permissions.refresh() }
    }
}
