import SwiftUI

struct ScreenshotsPane: View {
    @AppStorage(Pref.imageFormat.name) private var format = Pref.imageFormat.defaultValue
    @AppStorage(Pref.jpegQuality.name) private var quality = Pref.jpegQuality.defaultValue
    @AppStorage(Pref.watermarkEnabled.name) private var watermarkEnabled = Pref.watermarkEnabled.defaultValue
    @AppStorage(Pref.watermarkText.name) private var watermarkText = Pref.watermarkText.defaultValue
    @AppStorage(Pref.watermarkCorner.name) private var watermarkCorner = Pref.watermarkCorner.defaultValue
    @AppStorage(Pref.colorFormat.name) private var colorFormat = Pref.colorFormat.defaultValue

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
            }

            Section("Capture") {
                PrefToggle("Show cursor", Pref.showCursorInShots)
                PrefToggle("Capture window shadow", Pref.windowShadow)
                PrefToggle("Hide notch", Pref.hideNotch, detail: "Fills the menu bar with black on screens with a notch.")
                PrefToggle("Hide desktop icons while capturing", Pref.hideDesktopIconsInShots)
                PrefToggle("Freeze screen while selecting", Pref.freezeScreen)
                PrefToggle("Show crosshair", Pref.showCrosshair)
                PrefToggle("Show magnifier", Pref.showMagnifier)
                PrefIntPicker("Self-timer", Pref.selfTimerSeconds, options: [("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15)])
                Picker("Color picker", selection: $colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Editor") {
                PrefToggle("Close editor after copying", Pref.editorCloseAfterCopy, detail: "Copy also saves your edits to the screenshot and closes the editor.")
            }

            Section("Sharing") {
                PrefToggle("Hide sensitive info when sharing", Pref.hideSensitiveWhenSharing,
                           detail: "Pixelates emails, phone numbers, cards, IBANs, keys, IP addresses and faces in Copy for AI and Share, and replaces them with [redacted] in the copied text. The file itself is not changed.")
            }

            Section {
                PrefToggle("Add watermark", Pref.watermarkEnabled, detail: "On new screenshots and recordings.")
                if watermarkEnabled {
                    LabeledContent("Text") {
                        TextField("Text", text: $watermarkText, prompt: Text("@yourname")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    Picker("Position", selection: $watermarkCorner) {
                        ForEach(WatermarkCorner.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Watermark")
            }
        }
        .formStyle(.grouped)
    }
}
