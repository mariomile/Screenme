import Foundation

/// The settings an agent can read and change: every one in the Settings window, under the key it is stored with,
/// with what it takes. A change goes through the same store the Settings window uses, so the app reacts to it the same
/// way. Shortcuts, editor state and internal bookkeeping are left out.
struct AgentSetting {
    enum Kind {
        case bool
        /// One of these whole numbers.
        case integer([Int])
        case number(ClosedRange<Double>)
        case text
        /// One of these words.
        case choice([String])
        /// A path to an existing folder; `~` is expanded.
        case folder
        /// Written to the Keychain, never read back.
        case secret
    }

    let key: String
    let section: SettingsTab
    let summary: String
    let kind: Kind
    /// The stored value, as JSON.
    let read: () -> Any
    let defaultValue: Any
    /// Stores a value already checked against `kind`.
    let write: (Any) throws -> Void

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    /// The setting as `settings` lists it.
    var listing: [String: Any] {
        var entry: [String: Any] = ["key": key, "section": section.title, "description": summary, "value": read(),
                                    "type": typeName]
        if case .secret = kind {} else { entry["default"] = defaultValue }
        switch kind {
        case .integer(let options): entry["options"] = options
        case .choice(let options): entry["options"] = options
        case .number(let range): entry["range"] = [range.lowerBound, range.upperBound]
        default: break
        }
        return entry
    }

    private var typeName: String {
        switch kind {
        case .bool: "boolean"
        case .integer: "integer"
        case .number: "number"
        case .text: "string"
        case .choice: "choice"
        case .folder: "folder"
        case .secret: "secret"
        }
    }

    /// Checks `value` (JSON, or text from the command line) against the kind, stores it and returns what was stored.
    @discardableResult
    func set(_ value: Any) throws -> Any {
        let checked = try check(value)
        try write(checked)
        return read()
    }

    private func check(_ value: Any) throws -> Any {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON true and false arrive as numbers; only a boolean setting takes them.
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch kind {
        case .bool:
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            switch text?.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: throw Invalid(description: "\(key) takes true or false")
            }
        case .integer(let options):
            guard !isBool, let number = (value as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }) ?? text.flatMap(Int.init),
                  options.contains(number) else {
                throw Invalid(description: "\(key) takes one of \(options.map(String.init).joined(separator: ", "))")
            }
            return number
        case .number(let range):
            guard !isBool, let number = (value as? NSNumber)?.doubleValue ?? text.flatMap(Double.init), range.contains(number) else {
                throw Invalid(description: "\(key) takes a number from \(range.lowerBound) to \(range.upperBound)")
            }
            return number
        case .text, .secret:
            guard let text = value as? String else { throw Invalid(description: "\(key) takes text") }
            return text
        case .choice(let options):
            guard let text, options.contains(text) else {
                throw Invalid(description: "\(key) takes one of \(options.joined(separator: ", "))")
            }
            return text
        case .folder:
            guard let text, !text.isEmpty else { throw Invalid(description: "\(key) takes a folder path") }
            let path = (text as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                throw Invalid(description: "\(path) is not a folder")
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }
}

extension AgentSetting {
    static func bool(_ key: PrefKey<Bool>, _ section: SettingsTab, _ summary: String) -> AgentSetting {
        stored(key, section, summary, .bool)
    }

    static func integer(_ key: PrefKey<Int>, _ section: SettingsTab, _ summary: String, options: [Int]) -> AgentSetting {
        stored(key, section, summary, .integer(options))
    }

    static func number(_ key: PrefKey<Double>, _ section: SettingsTab, _ summary: String, range: ClosedRange<Double>) -> AgentSetting {
        stored(key, section, summary, .number(range))
    }

    static func text(_ key: PrefKey<String>, _ section: SettingsTab, _ summary: String) -> AgentSetting {
        stored(key, section, summary, .text)
    }

    static func folder(_ key: PrefKey<String>, _ section: SettingsTab, _ summary: String) -> AgentSetting {
        stored(key, section, summary, .folder)
    }

    /// An enum setting, stored as its raw value the way `@AppStorage` stores it.
    static func choice<Value: RawRepresentable>(_ key: PrefKey<Value>, _ section: SettingsTab, _ summary: String,
                                                options: [Value]) -> AgentSetting where Value.RawValue == String {
        AgentSetting(key: key.name, section: section, summary: summary, kind: .choice(options.map(\.rawValue)),
                     read: { Prefs[key].rawValue }, defaultValue: key.defaultValue.rawValue,
                     write: { Prefs.store.set($0 as? String, forKey: key.name) })
    }

    private static func stored<Value>(_ key: PrefKey<Value>, _ section: SettingsTab, _ summary: String, _ kind: Kind) -> AgentSetting {
        AgentSetting(key: key.name, section: section, summary: summary, kind: kind, read: { Prefs[key] },
                     defaultValue: key.defaultValue, write: { Prefs.store.set($0, forKey: key.name) })
    }

    static let s3SecretAccessKey = AgentSetting(
        key: "s3SecretAccessKey", section: .upload, summary: "Secret Access Key of the bucket. Stored in the Keychain; reads say only whether it is set.",
        kind: .secret, read: { S3Keychain.read().isEmpty ? "" : "(set)" }, defaultValue: "",
        write: { try S3Keychain.write($0 as? String ?? "") })

    /// Every setting, in the order of the Settings window.
    static let all: [AgentSetting] = [
        bool(Pref.playSounds, .general, "A shutter sound after screenshots and ticks during countdowns."),
        bool(Pref.showMenuBarIcon, .general, "Shows the Screenme icon in the menu bar."),
        folder(Pref.saveDirectory, .general, "The save folder: where Save, Copy as Markdown and Reports for AI write files."),
        text(Pref.fileNamePrefix, .general, "The start of every file name, before the date."),
        bool(Pref.afterShotQuickAccess, .general, "After a screenshot: show the Quick Access card."),
        bool(Pref.afterShotCopy, .general, "After a screenshot: copy it to the clipboard."),
        bool(Pref.afterShotSave, .general, "After a screenshot: save a copy to the save folder."),
        bool(Pref.afterShotOpenEditor, .general, "After a screenshot: open the annotation editor instead of Quick Access."),
        bool(Pref.afterShotPin, .general, "After a screenshot: pin it to the screen."),
        bool(Pref.afterRecordingQuickAccess, .recording, "After a recording: show the Quick Access card."),
        bool(Pref.afterRecordingCopy, .recording, "After a recording: copy it to the clipboard."),
        bool(Pref.afterRecordingSave, .recording, "After a recording: save a copy to the save folder."),
        bool(Pref.afterRecordingOpenEditor, .recording, "After a recording: open the video editor."),
        bool(Pref.afterRecordingAIReport, .recording, "After a recording: make a Report for AI."),
        bool(Pref.reportAutoCrop, .recording, "Reports for AI crop each keyframe to the window being worked in."),

        choice(Pref.imageFormat, .screenshots, "File format of screenshots.", options: ImageFormat.allCases),
        number(Pref.jpegQuality, .screenshots, "JPEG quality, when the format is jpg.", range: 0.5...1),
        bool(Pref.retinaResolution, .screenshots, "Saves at full Retina resolution; off saves at 1x, smaller files."),
        bool(Pref.showCursorInShots, .screenshots, "Shows the pointer in screenshots."),
        bool(Pref.windowShadow, .screenshots, "Keeps the shadow around window captures."),
        bool(Pref.hideNotch, .screenshots, "Fills the menu bar with black on screens with a notch."),
        bool(Pref.hideDesktopIconsInShots, .screenshots, "Hides desktop icons while taking a screenshot."),
        bool(Pref.freezeScreen, .screenshots, "Freezes the screen while you pick an area, so menus and hover states hold still."),
        bool(Pref.showCrosshair, .screenshots, "Shows a crosshair while picking an area."),
        bool(Pref.showMagnifier, .screenshots, "Shows a magnifier while picking an area."),
        integer(Pref.selfTimerSeconds, .screenshots, "Seconds the self-timer counts down.", options: [3, 5, 10, 15]),
        choice(Pref.colorFormat, .screenshots, "How Pick Color copies a color.", options: ColorFormat.allCases),
        bool(Pref.editorCloseAfterCopy, .screenshots, "Copy in the editor also saves the edits and closes it."),
        bool(Pref.hideSensitiveWhenSharing, .screenshots, "Share, upload and Copy for AI hide emails, keys, cards and faces in the copy."),
        bool(Pref.watermarkEnabled, .screenshots, "Puts a watermark on new screenshots and recordings."),
        text(Pref.watermarkText, .screenshots, "The watermark's text."),
        choice(Pref.watermarkCorner, .screenshots, "The watermark's corner.", options: WatermarkCorner.allCases),

        choice(Pref.quickAccessPosition, .quickAccess, "Which corner Quick Access cards appear in.", options: [QuickAccessPosition.bottomLeft, .bottomRight]),
        choice(Pref.quickAccessSize, .quickAccess, "Size of Quick Access cards.", options: QuickAccessSize.allCases),
        integer(Pref.quickAccessAutoClose, .quickAccess, "Seconds before a card closes by itself; 0 never.", options: [0, 3, 5, 10, 15, 30]),
        bool(Pref.quickAccessAutoCloseSaves, .quickAccess, "A card that closes by itself saves its capture first."),
        bool(Pref.quickAccessCloseAfterDrag, .quickAccess, "A card closes after its capture is dragged into an app."),

        choice(Pref.recordingFormat, .recording, "Recordings as video (MP4) or GIF.", options: [RecordingFormat.video, .gif]),
        integer(Pref.recordingFPS, .recording, "Frame rate of recordings.", options: [30, 60]),
        choice(Pref.recordingQuality, .recording, "Encoder quality of recordings and exports.", options: VideoQuality.allCases),
        integer(Pref.recordingCountdown, .recording, "Seconds counted down before a recording starts; 0 none.", options: [0, 3, 5, 10]),
        bool(Pref.recordingShowCursor, .recording, "Shows the pointer in recordings."),
        bool(Pref.recordingSmoothCursor, .recording, "Smooths the pointer's movement in the finished video."),
        bool(Pref.recordingHighlightClicks, .recording, "Shows a ring where you click."),
        bool(Pref.recordingShowKeystrokes, .recording, "Shows the keys you press."),
        bool(Pref.recordingMicrophone, .recording, "Records the microphone."),
        text(Pref.recordingMicrophoneID, .recording, "The microphone's device ID; empty is the system default."),
        bool(Pref.recordingSystemAudio, .recording, "Records the sound the Mac plays."),
        bool(Pref.recordingWebcam, .recording, "Shows the camera in a bubble."),
        text(Pref.recordingWebcamID, .recording, "The camera's device ID; empty is the default camera."),
        choice(Pref.recordingWebcamSize, .recording, "Size of the camera bubble.", options: [WebcamSize.small, .medium, .large]),
        bool(Pref.recordingHideDesktopIcons, .recording, "Hides desktop icons while recording."),
        bool(Pref.recordingHideNotifications, .recording, "Leaves notification banners out of the video."),

        text(Pref.s3Endpoint, .upload, "S3-compatible endpoint, like https://ACCOUNT.r2.cloudflarestorage.com."),
        text(Pref.s3Region, .upload, "The bucket's region; auto for Cloudflare R2."),
        text(Pref.s3Bucket, .upload, "The bucket name."),
        text(Pref.s3AccessKeyID, .upload, "Access Key ID of the bucket."),
        s3SecretAccessKey,
        text(Pref.s3PublicURL, .upload, "The public address files are served from, like https://shots.example.com."),

        bool(Pref.ocrKeepLineBreaks, .text, "Keeps line breaks in recognized text; off joins the lines of a paragraph."),
        bool(Pref.ocrDetectQR, .text, "Reads QR codes and barcodes too."),
        text(Pref.ocrLanguage, .text, "Language code for text recognition, like it or en-US; empty detects it."),
        text(Pref.translateTarget, .text, "Language code to translate into; empty is the system language."),

        integer(Pref.historyDays, .history, "Days captures stay in History; 0 forever.", options: [1, 7, 14, 30, 90, 365, 0]),
    ]

    static func named(_ key: String) -> AgentSetting? {
        all.first { $0.key == key }
    }
}
