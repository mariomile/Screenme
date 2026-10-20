import AppKit
import AVFoundation
import CoreMedia

// MARK: - Preferences owned by the recording module

extension Pref {
    static let recordingFormat = PrefKey(name: "recordingFormat", defaultValue: RecordingFormat.video)
    static let recordingWebcamSize = PrefKey(name: "recordingWebcamSize", defaultValue: WebcamSize.medium)
    static let recordingWebcamID = PrefKey(name: "recordingWebcamID", defaultValue: "") // "" = default camera
}

enum RecordingFormat: String {
    case video, gif
}

enum WebcamSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var diameter: CGFloat {
        switch self {
        case .small: 120
        case .medium: 180
        case .large: 260
        }
    }
}

/// A snapshot of the recording preferences, read when the user presses Record.
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
    var countdown: Int
    var hideDesktopIcons: Bool

    static func current() -> RecordingSettings {
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
            countdown: max(0, Prefs[Pref.recordingCountdown]),
            hideDesktopIcons: Prefs[Pref.recordingHideDesktopIcons])
    }
}

/// How the stream is filmed for the chosen format, resolved once from the settings.
struct CaptureProfile {
    let retina: Bool
    let fps: Int
    let capturesAudio: Bool
}

extension RecordingSettings {
    /// GIFs are filmed at 1x, at most 30 fps and without sound: they end up small and silent anyway.
    var profile: CaptureProfile {
        switch format {
        case .video: CaptureProfile(retina: true, fps: fps, capturesAudio: true)
        case .gif: CaptureProfile(retina: false, fps: min(fps, 30), capturesAudio: false)
        }
    }
}

// MARK: - Sample buffer timing

extension CMSampleBuffer {
    /// A copy with every timestamp moved earlier by `delta`.
    func shifted(by delta: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for index in infos.indices {
            infos[index].presentationTimeStamp = CMTimeSubtract(infos[index].presentationTimeStamp, delta)
            if infos[index].decodeTimeStamp.isValid {
                infos[index].decodeTimeStamp = CMTimeSubtract(infos[index].decodeTimeStamp, delta)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: self,
                                                           sampleTimingEntryCount: count, sampleTimingArray: infos,
                                                           sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
