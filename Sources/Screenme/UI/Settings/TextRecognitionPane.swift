import SwiftUI

struct TextRecognitionPane: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    var body: some View {
        Form {
            Section {
                PrefToggle("Keep line breaks", Pref.ocrKeepLineBreaks, detail: "Off joins the lines of a paragraph into one.")
                PrefToggle("Detect QR codes", Pref.ocrDetectQR, detail: "Copies the link or text a QR code holds.")
            } footer: {
                HStack(spacing: 6) {
                    Text("Select an area to copy its text.")
                    if let combo = shortcuts.combo(for: .captureText) { Text("Shortcut:"); KeyCaps(combo: combo, size: 10) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
