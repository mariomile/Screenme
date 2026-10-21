import AppKit
import SwiftUI

struct GeneralPane: View {
    @AppStorage(Pref.fileNamePrefix.name) private var prefix = Pref.fileNamePrefix.defaultValue
    @AppStorage(Pref.imageFormat.name) private var format = Pref.imageFormat.defaultValue

    /// The name the next screenshot would get, from the rule `Storage` uses. Redrawn as the prefix changes.
    private var exampleName: String {
        Storage.newURL(extension: format.fileExtension).lastPathComponent
    }

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
            }

            Section {
                SaveFolderRow()
                LabeledContent("File name prefix") {
                    TextField("File name prefix", text: $prefix, prompt: Text("Screenme")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LabeledContent("Example") {
                    Text(exampleName).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Saving")
            } footer: {
                Text("Save, the Save to folder options and auto-save put screenshots and recordings here. Captures also stay in History.")
            }

            Section("Feedback") {
                PrefToggle("Play sounds", Pref.playSounds, detail: "A shutter sound after screenshots and ticks during countdowns.")
            }

            Section {
                PrefToggle("Show menu bar icon", Pref.showMenuBarIcon,
                           detail: "When hidden, open Screenme again from Applications or Spotlight to reach Settings.")
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
