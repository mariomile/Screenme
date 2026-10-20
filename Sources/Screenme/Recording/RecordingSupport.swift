import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

// MARK: - Preferences owned by the recording module

extension Pref {
    static let recordingFormat = PrefKey(name: "recordingFormat", defaultValue: "video") // "video" | "gif"
    static let recordingWebcamSize = PrefKey(name: "recordingWebcamSize", defaultValue: "medium") // "small" | "medium" | "large"
    static let recordingWebcamID = PrefKey(name: "recordingWebcamID", defaultValue: "") // "" = default camera
}

enum RecordingPrefs {
    /// Registers this module's defaults. Touched on first use of the recorder.
    static let registered: Void = {
        Prefs.store.register(defaults: [
            Pref.recordingFormat.name: Pref.recordingFormat.defaultValue,
            Pref.recordingWebcamSize.name: Pref.recordingWebcamSize.defaultValue,
            Pref.recordingWebcamID.name: Pref.recordingWebcamID.defaultValue,
        ])
    }()
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
    var quality: String
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
            format: RecordingFormat(rawValue: Prefs[Pref.recordingFormat]) ?? .video,
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

    /// Bits per pixel per frame for the H.264 encoder.
    static func bitsPerPixel(quality: String) -> Double {
        switch quality {
        case "low": 0.035
        case "medium": 0.07
        default: 0.14
        }
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

// MARK: - Panels

/// A borderless floating panel that never activates the app it belongs to.
final class FloatingPanel: NSPanel {
    private let allowsKey: Bool

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect, level: NSWindow.Level, canBeKey: Bool = false, hasShadow: Bool = true) {
        allowsKey = canBeKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        self.hasShadow = hasShadow
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Fades the panel in.
    func present(makeKey: Bool = false) {
        alphaValue = 0
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    /// Fades the panel out and removes it.
    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }
}

/// Dark, blurred background used by every recording control.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Placement

enum Placement {
    static func screen(containing frame: CGRect) -> NSScreen {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The screen a target lives on.
    static func screen(for target: CaptureTarget) -> NSScreen {
        switch target {
        case .area(_, let screen), .display(let screen): screen
        case .window: screen(containing: target.cocoaFrame)
        }
    }

    /// Puts a bar of `size` just below `area`, or above it, or inside its bottom edge when neither fits.
    static func barFrame(size: CGSize, near area: CGRect, on screen: NSScreen, gap: CGFloat = 14) -> CGRect {
        let visible = screen.visibleFrame
        var y = area.minY - gap - size.height
        if y < visible.minY + 8 {
            y = area.maxY + gap
            if y + size.height > visible.maxY - 8 {
                y = max(visible.minY + 8, area.minY + 20)
            }
        }
        var x = area.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
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
        let visible = CaptureCoordinator.shared.screenUnderMouse.visibleFrame
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height)
        let panel = FloatingPanel(frame: frame, level: .statusBar)
        panel.ignoresMouseEvents = true
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
