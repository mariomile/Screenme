import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

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

// MARK: - Permissions

enum MediaAccess {
    /// True when the app may use `type`. Asks the user the first time.
    static func ensure(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    static func isAuthorized(_ type: AVMediaType) -> Bool {
        AVCaptureDevice.authorizationStatus(for: type) == .authorized
    }

    /// Tells the user how to fix a denied permission and opens the right pane.
    @MainActor
    static func explainDenied(_ type: AVMediaType) {
        let microphone = type == .audio
        Toast.show(microphone ? "Microphone access is off. Allow Screenme in Privacy settings."
                              : "Camera access is off. Allow Screenme in Privacy settings.",
                   symbol: microphone ? "mic.slash.fill" : "video.slash.fill", duration: 3)
        let pane = microphone ? "Privacy_Microphone" : "Privacy_Camera"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy > Accessibility.
    static func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

// MARK: - Devices

enum InputDevices {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
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

// MARK: - Small shared UI

/// A tiny progress HUD at the bottom of the screen, e.g. while a recording becomes a GIF.
@MainActor
final class ProgressHUD {
    private final class Model: ObservableObject {
        @Published var title: String
        @Published var progress: Double = 0
        init(title: String) { self.title = title }
    }

    private let model: Model
    private var panel: FloatingPanel?

    init(title: String) {
        model = Model(title: title)
    }

    func show() {
        let view = NSHostingView(rootView: ProgressHUDView(model: model))
        let size = view.fittingSize
        let visible = NSScreen.underMouse.visibleFrame
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height)
        let panel = FloatingPanel(frame: frame, level: .statusBar, ignoresMouse: true)
        panel.contentView = view
        panel.present()
        self.panel = panel
    }

    func update(_ progress: Double, title: String? = nil) {
        model.progress = min(max(progress, 0), 1)
        if let title { model.title = title }
    }

    func hide() {
        panel?.dismiss()
        panel = nil
    }

    private struct ProgressHUDView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(spacing: 8) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 180)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
            .padding(8)
        }
    }
}
