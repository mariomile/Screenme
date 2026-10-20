import SwiftUI

struct ScreenshotsPane: View {
    @AppStorage(Pref.imageFormat.name) private var format = Pref.imageFormat.defaultValue
    @AppStorage(Pref.jpegQuality.name) private var quality = Pref.jpegQuality.defaultValue
    @AppStorage(Pref.fileNamePrefix.name) private var prefix = Pref.fileNamePrefix.defaultValue

    /// The name the next capture would get, from the rule `Storage` uses. Redrawn as the prefix changes.
    private var exampleName: String {
        Storage.newURL(extension: format.fileExtension).lastPathComponent
    }

    var body: some View {
        Form {
            AfterCaptureSection()

            Section("File") {
                Picker("Format", selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if format == .jpg {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.5...1, step: 0.05).frame(width: 180)
                            Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                PrefToggle("Save at Retina resolution", Pref.retinaResolution, detail: "Turn off to save at 1x, which makes smaller files.")
                LabeledContent("File name prefix") {
                    TextField("File name prefix", text: $prefix, prompt: Text("Screenme")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LabeledContent("Example") {
                    Text(exampleName).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                SaveFolderRow()
            }

            Section("Capture") {
                PrefToggle("Show cursor", Pref.showCursorInShots)
                PrefToggle("Capture window shadow", Pref.windowShadow)
                PrefToggle("Freeze screen while selecting", Pref.freezeScreen)
                PrefToggle("Show crosshair", Pref.showCrosshair)
                PrefToggle("Show magnifier", Pref.showMagnifier)
                PrefIntPicker("Self-timer", Pref.selfTimerSeconds, options: [("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15)])
            }
        }
        .formStyle(.grouped)
    }
}
