import Foundation
import UniformTypeIdentifiers

/// A typed UserDefaults key. SwiftUI views bind with `@AppStorage(Pref.x.name) var x = Pref.x.defaultValue`;
/// other code reads and writes with `Prefs[Pref.x]`. Every read falls back to `defaultValue`,
/// so nothing is registered.
struct PrefKey<Value> {
    let name: String
    let defaultValue: Value
}

enum Prefs {
    static var store = UserDefaults.standard // var so tests can swap in a throwaway suite

    static subscript<Value>(key: PrefKey<Value>) -> Value {
        get { store.object(forKey: key.name) as? Value ?? key.defaultValue }
        set { store.set(newValue, forKey: key.name) }
    }

    /// Enum preferences are stored as their raw value, the same way `@AppStorage` stores them.
    static subscript<Value: RawRepresentable>(key: PrefKey<Value>) -> Value {
        get { (store.object(forKey: key.name) as? Value.RawValue).flatMap(Value.init(rawValue:)) ?? key.defaultValue }
        set { store.set(newValue.rawValue, forKey: key.name) }
    }

    static func remove<Value>(_ key: PrefKey<Value>) {
        store.removeObject(forKey: key.name)
    }
}

/// Every preference in the app. Modules that need more add `extension Pref { static let … }` in their own files.
enum Pref {
    // General
    static let playSounds = PrefKey(name: "playSounds", defaultValue: false)
    static let showMenuBarIcon = PrefKey(name: "showMenuBarIcon", defaultValue: true)
    static let settingsTab = PrefKey(name: "settingsSelectedTab", defaultValue: SettingsTab.general)
    /// JSON `[action: KeyCombo?]`, owned by `ShortcutStore`. Empty means every action uses its default.
    static let shortcuts = PrefKey(name: "shortcuts", defaultValue: Data())

    // After a screenshot
    static let afterShotQuickAccess = PrefKey(name: "afterShotQuickAccess", defaultValue: true)
    static let afterShotCopy = PrefKey(name: "afterShotCopy", defaultValue: true)
    static let afterShotSave = PrefKey(name: "afterShotSave", defaultValue: false)
    static let afterShotOpenEditor = PrefKey(name: "afterShotOpenEditor", defaultValue: false)
    static let afterShotPin = PrefKey(name: "afterShotPin", defaultValue: false)

    // After a recording
    static let afterRecordingQuickAccess = PrefKey(name: "afterRecordingQuickAccess", defaultValue: true)
    static let afterRecordingCopy = PrefKey(name: "afterRecordingCopy", defaultValue: false)
    static let afterRecordingSave = PrefKey(name: "afterRecordingSave", defaultValue: false)
    static let afterRecordingOpenEditor = PrefKey(name: "afterRecordingOpenEditor", defaultValue: false)

    // Files
    static let saveDirectory = PrefKey(name: "saveDirectory", defaultValue: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path)
    static let imageFormat = PrefKey(name: "imageFormat", defaultValue: ImageFormat.png)
    static let jpegQuality = PrefKey(name: "jpegQuality", defaultValue: 0.9)
    static let retinaResolution = PrefKey(name: "retinaResolution", defaultValue: true) // false = save at 1x
    static let fileNamePrefix = PrefKey(name: "fileNamePrefix", defaultValue: "Screenme")

    // Screenshots
    static let showCursorInShots = PrefKey(name: "showCursorInShots", defaultValue: false)
    static let freezeScreen = PrefKey(name: "freezeScreen", defaultValue: false)
    static let showMagnifier = PrefKey(name: "showMagnifier", defaultValue: true)
    static let showCrosshair = PrefKey(name: "showCrosshair", defaultValue: true)
    static let windowShadow = PrefKey(name: "windowShadow", defaultValue: true)
    static let hideNotch = PrefKey(name: "hideNotch", defaultValue: false)
    static let hideDesktopIconsInShots = PrefKey(name: "hideDesktopIconsInShots", defaultValue: false)
    static let selfTimerSeconds = PrefKey(name: "selfTimerSeconds", defaultValue: 5)

    // Quick Access
    static let quickAccessPosition = PrefKey(name: "quickAccessPosition", defaultValue: QuickAccessPosition.bottomLeft)
    static let quickAccessAutoClose = PrefKey(name: "quickAccessAutoClose", defaultValue: 0) // seconds, 0 = never
    static let quickAccessAutoCloseSaves = PrefKey(name: "quickAccessAutoCloseSaves", defaultValue: false)
    static let quickAccessCloseAfterDrag = PrefKey(name: "quickAccessCloseAfterDrag", defaultValue: true)
    static let quickAccessSize = PrefKey(name: "quickAccessSize", defaultValue: QuickAccessSize.medium)

    // Recording
    static let recordingFPS = PrefKey(name: "recordingFPS", defaultValue: 30) // 30 | 60
    static let recordingQuality = PrefKey(name: "recordingQuality", defaultValue: VideoQuality.high)
    static let recordingShowCursor = PrefKey(name: "recordingShowCursor", defaultValue: true)
    static let recordingHighlightClicks = PrefKey(name: "recordingHighlightClicks", defaultValue: false)
    static let recordingShowKeystrokes = PrefKey(name: "recordingShowKeystrokes", defaultValue: false)
    static let recordingMicrophone = PrefKey(name: "recordingMicrophone", defaultValue: false)
    static let recordingMicrophoneID = PrefKey(name: "recordingMicrophoneID", defaultValue: "")
    static let recordingSystemAudio = PrefKey(name: "recordingSystemAudio", defaultValue: false)
    static let recordingWebcam = PrefKey(name: "recordingWebcam", defaultValue: false)
    static let recordingCountdown = PrefKey(name: "recordingCountdown", defaultValue: 3)
    static let recordingHideDesktopIcons = PrefKey(name: "recordingHideDesktopIcons", defaultValue: false)
    static let recordingHideNotifications = PrefKey(name: "recordingHideNotifications", defaultValue: true)

    // Text recognition
    static let ocrKeepLineBreaks = PrefKey(name: "ocrKeepLineBreaks", defaultValue: true)
    static let ocrDetectQR = PrefKey(name: "ocrDetectQR", defaultValue: true)
    static let ocrLanguage = PrefKey(name: "ocrLanguage", defaultValue: "") // "" = detect automatically

    // History
    static let historyDays = PrefKey(name: "historyDays", defaultValue: 30) // 0 = keep forever

    // Onboarding
    static let onboardingDone = PrefKey(name: "onboardingDone", defaultValue: false)
    static let onboardingStep = PrefKey(name: "onboardingStep", defaultValue: 0)
}

// MARK: - Preference values

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { rawValue }
    var type: UTType { self == .png ? .png : .jpeg }

    /// The format of an existing file, from its extension.
    init(of url: URL) {
        self = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpg : .png
    }
}

enum QuickAccessPosition: String {
    case bottomLeft, bottomRight
}

enum QuickAccessSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var cardWidth: CGFloat {
        switch self {
        case .small: 180
        case .medium: 224
        case .large: 280
        }
    }
}

/// Encoder quality for recordings and video editor exports.
enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, low

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Bits per pixel per frame for the H.264 encoder.
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.14
        case .medium: 0.07
        case .low: 0.035
        }
    }

    var gifColors: Int {
        switch self {
        case .high: 255
        case .medium: 128
        case .low: 64
        }
    }

    var gifDither: Bool { self == .high }
}
