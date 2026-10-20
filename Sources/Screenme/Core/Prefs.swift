import Foundation

/// A typed UserDefaults key. SwiftUI views bind with `@AppStorage(Pref.x.name)`;
/// other code reads and writes with `Prefs[Pref.x]`.
struct PrefKey<Value> {
    let name: String
    let defaultValue: Value
}

enum Prefs {
    static let store = UserDefaults.standard

    static subscript<Value>(key: PrefKey<Value>) -> Value {
        get { store.object(forKey: key.name) as? Value ?? key.defaultValue }
        set { store.set(newValue, forKey: key.name) }
    }

    /// Registered at launch so `@AppStorage` and `Prefs[...]` agree on defaults.
    static func registerDefaults() {
        store.register(defaults: Pref.allDefaults)
    }
}

/// Every preference in the app. Modules that need more add `extension Pref { static let … }`
/// in their own files and register the default there.
enum Pref {
    // General
    static let playSounds = PrefKey(name: "playSounds", defaultValue: true)

    // After a screenshot
    static let afterShotQuickAccess = PrefKey(name: "afterShotQuickAccess", defaultValue: true)
    static let afterShotCopy = PrefKey(name: "afterShotCopy", defaultValue: true)
    static let afterShotSave = PrefKey(name: "afterShotSave", defaultValue: false)
    static let afterShotOpenEditor = PrefKey(name: "afterShotOpenEditor", defaultValue: false)

    // After a recording
    static let afterRecordingQuickAccess = PrefKey(name: "afterRecordingQuickAccess", defaultValue: true)
    static let afterRecordingCopy = PrefKey(name: "afterRecordingCopy", defaultValue: false)
    static let afterRecordingSave = PrefKey(name: "afterRecordingSave", defaultValue: false)

    // Files
    static let saveDirectory = PrefKey(name: "saveDirectory", defaultValue: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path)
    static let imageFormat = PrefKey(name: "imageFormat", defaultValue: "png") // "png" | "jpg"
    static let jpegQuality = PrefKey(name: "jpegQuality", defaultValue: 0.9)
    static let retinaResolution = PrefKey(name: "retinaResolution", defaultValue: true) // false = save at 1x
    static let fileNamePrefix = PrefKey(name: "fileNamePrefix", defaultValue: "Screenme")

    // Screenshots
    static let showCursorInShots = PrefKey(name: "showCursorInShots", defaultValue: false)
    static let freezeScreen = PrefKey(name: "freezeScreen", defaultValue: false)
    static let showMagnifier = PrefKey(name: "showMagnifier", defaultValue: true)
    static let showCrosshair = PrefKey(name: "showCrosshair", defaultValue: true)
    static let windowShadow = PrefKey(name: "windowShadow", defaultValue: true)
    static let selfTimerSeconds = PrefKey(name: "selfTimerSeconds", defaultValue: 5)

    // Quick Access
    static let quickAccessPosition = PrefKey(name: "quickAccessPosition", defaultValue: "bottomLeft") // "bottomLeft" | "bottomRight"
    static let quickAccessAutoClose = PrefKey(name: "quickAccessAutoClose", defaultValue: 0) // seconds, 0 = never

    // Recording
    static let recordingFPS = PrefKey(name: "recordingFPS", defaultValue: 30) // 30 | 60
    static let recordingQuality = PrefKey(name: "recordingQuality", defaultValue: "high") // "high" | "medium" | "low"
    static let recordingShowCursor = PrefKey(name: "recordingShowCursor", defaultValue: true)
    static let recordingHighlightClicks = PrefKey(name: "recordingHighlightClicks", defaultValue: false)
    static let recordingShowKeystrokes = PrefKey(name: "recordingShowKeystrokes", defaultValue: false)
    static let recordingMicrophone = PrefKey(name: "recordingMicrophone", defaultValue: false)
    static let recordingMicrophoneID = PrefKey(name: "recordingMicrophoneID", defaultValue: "")
    static let recordingSystemAudio = PrefKey(name: "recordingSystemAudio", defaultValue: false)
    static let recordingWebcam = PrefKey(name: "recordingWebcam", defaultValue: false)
    static let recordingCountdown = PrefKey(name: "recordingCountdown", defaultValue: 3)
    static let recordingHideDesktopIcons = PrefKey(name: "recordingHideDesktopIcons", defaultValue: false)

    // Text recognition
    static let ocrKeepLineBreaks = PrefKey(name: "ocrKeepLineBreaks", defaultValue: true)
    static let ocrDetectQR = PrefKey(name: "ocrDetectQR", defaultValue: true)

    // History
    static let historyDays = PrefKey(name: "historyDays", defaultValue: 30) // 0 = keep forever

    // Onboarding
    static let onboardingDone = PrefKey(name: "onboardingDone", defaultValue: false)
    static let onboardingStep = PrefKey(name: "onboardingStep", defaultValue: 0)

    static let allDefaults: [String: Any] = [
        playSounds.name: playSounds.defaultValue,
        afterShotQuickAccess.name: afterShotQuickAccess.defaultValue,
        afterShotCopy.name: afterShotCopy.defaultValue,
        afterShotSave.name: afterShotSave.defaultValue,
        afterShotOpenEditor.name: afterShotOpenEditor.defaultValue,
        afterRecordingQuickAccess.name: afterRecordingQuickAccess.defaultValue,
        afterRecordingCopy.name: afterRecordingCopy.defaultValue,
        afterRecordingSave.name: afterRecordingSave.defaultValue,
        saveDirectory.name: saveDirectory.defaultValue,
        imageFormat.name: imageFormat.defaultValue,
        jpegQuality.name: jpegQuality.defaultValue,
        retinaResolution.name: retinaResolution.defaultValue,
        fileNamePrefix.name: fileNamePrefix.defaultValue,
        showCursorInShots.name: showCursorInShots.defaultValue,
        freezeScreen.name: freezeScreen.defaultValue,
        showMagnifier.name: showMagnifier.defaultValue,
        showCrosshair.name: showCrosshair.defaultValue,
        windowShadow.name: windowShadow.defaultValue,
        selfTimerSeconds.name: selfTimerSeconds.defaultValue,
        quickAccessPosition.name: quickAccessPosition.defaultValue,
        quickAccessAutoClose.name: quickAccessAutoClose.defaultValue,
        recordingFPS.name: recordingFPS.defaultValue,
        recordingQuality.name: recordingQuality.defaultValue,
        recordingShowCursor.name: recordingShowCursor.defaultValue,
        recordingHighlightClicks.name: recordingHighlightClicks.defaultValue,
        recordingShowKeystrokes.name: recordingShowKeystrokes.defaultValue,
        recordingMicrophone.name: recordingMicrophone.defaultValue,
        recordingMicrophoneID.name: recordingMicrophoneID.defaultValue,
        recordingSystemAudio.name: recordingSystemAudio.defaultValue,
        recordingWebcam.name: recordingWebcam.defaultValue,
        recordingCountdown.name: recordingCountdown.defaultValue,
        recordingHideDesktopIcons.name: recordingHideDesktopIcons.defaultValue,
        ocrKeepLineBreaks.name: ocrKeepLineBreaks.defaultValue,
        ocrDetectQR.name: ocrDetectQR.defaultValue,
        historyDays.name: historyDays.defaultValue,
        onboardingDone.name: onboardingDone.defaultValue,
        onboardingStep.name: onboardingStep.defaultValue,
    ]
}
