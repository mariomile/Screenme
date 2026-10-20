import AppKit
import SwiftUI

struct GeneralPane: View {
    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
            }

            Section("Feedback") {
                PrefToggle("Play sounds", Pref.playSounds, detail: "A shutter sound after each screenshot.")
            }

            Section {
                LabeledContent("Menu bar") {
                    Text("Screenme lives in the menu bar").foregroundStyle(.secondary)
                }
                LabeledContent("Welcome guide") {
                    Button("Show Welcome Guide…") { OnboardingWindow.show() }
                }
                LabeledContent("Quit") {
                    Button("Quit Screenme") { NSApp.terminate(nil) }
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Click the menu bar icon to capture, record or open History. Closing this window keeps Screenme running.")
            }
        }
        .formStyle(.grouped)
    }
}
