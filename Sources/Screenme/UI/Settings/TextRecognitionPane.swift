import SwiftUI

struct TextRecognitionPane: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared
    @AppStorage(Pref.ocrLanguage.name) private var language = Pref.ocrLanguage.defaultValue
    private let languages = TextRecognizer.supportedLanguages

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("Detect automatically").tag("")
                    Divider()
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
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
