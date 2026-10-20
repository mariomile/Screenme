import Foundation

extension Pref {
    static let recordingFormat = PrefKey(name: "recordingFormat", defaultValue: RecordingFormat.video)
    static let recordingWebcamSize = PrefKey(name: "recordingWebcamSize", defaultValue: WebcamSize.medium)
    static let recordingWebcamID = PrefKey(name: "recordingWebcamID", defaultValue: "") // "" = default camera
}

enum RecordingFormat: String {
    case video, gif
}

/// Everything that shapes one recording. The pre-record bar edits a copy and hands it to the recording when
/// the user presses Record; frame rate and quality come from Settings.
struct RecordingSettings {
    var format: RecordingFormat
    var fps: Int
    var quality: VideoQuality
    var showCursor: Bool
    var highlightClicks: Bool
    var showKeystrokes: Bool
    var microphone: Bool
    var microphoneID: String
    var systemAudio: Bool
    var webcam: Bool
    var webcamSize: WebcamSize
    var webcamID: String
    var countdown: Int
    var hideDesktopIcons: Bool

    /// The settings as last saved.
    static var saved: RecordingSettings {
        RecordingSettings(
            format: Prefs[Pref.recordingFormat],
            fps: Prefs[Pref.recordingFPS] >= 60 ? 60 : 30,
            quality: Prefs[Pref.recordingQuality],
            showCursor: Prefs[Pref.recordingShowCursor],
            highlightClicks: Prefs[Pref.recordingHighlightClicks],
            showKeystrokes: Prefs[Pref.recordingShowKeystrokes],
            microphone: Prefs[Pref.recordingMicrophone],
            microphoneID: Prefs[Pref.recordingMicrophoneID],
            systemAudio: Prefs[Pref.recordingSystemAudio],
            webcam: Prefs[Pref.recordingWebcam],
            webcamSize: Prefs[Pref.recordingWebcamSize],
            webcamID: Prefs[Pref.recordingWebcamID],
            countdown: max(0, Prefs[Pref.recordingCountdown]),
            hideDesktopIcons: Prefs[Pref.recordingHideDesktopIcons])
    }

    /// Saves what the pre-record bar edits. Frame rate and quality belong to Settings and are left alone.
    func save() {
        Prefs[Pref.recordingFormat] = format
        Prefs[Pref.recordingShowCursor] = showCursor
        Prefs[Pref.recordingHighlightClicks] = highlightClicks
        Prefs[Pref.recordingShowKeystrokes] = showKeystrokes
        Prefs[Pref.recordingMicrophone] = microphone
        Prefs[Pref.recordingMicrophoneID] = microphoneID
        Prefs[Pref.recordingSystemAudio] = systemAudio
        Prefs[Pref.recordingWebcam] = webcam
        Prefs[Pref.recordingWebcamSize] = webcamSize
        Prefs[Pref.recordingWebcamID] = webcamID
        Prefs[Pref.recordingCountdown] = countdown
        Prefs[Pref.recordingHideDesktopIcons] = hideDesktopIcons
    }

    /// How the stream is filmed for the chosen format. GIFs are filmed at 1x, at most 30 fps and without sound:
    /// they end up small and silent anyway.
    var profile: CaptureProfile {
        switch format {
        case .video: CaptureProfile(retina: true, fps: fps, capturesAudio: true)
        case .gif: CaptureProfile(retina: false, fps: min(fps, 30), capturesAudio: false)
        }
    }
}

struct CaptureProfile {
    let retina: Bool
    let fps: Int
    let capturesAudio: Bool
}
