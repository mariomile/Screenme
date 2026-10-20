import AppKit
import CoreMedia
import ScreenCaptureKit

/// Everything ScreenCaptureKit needs for one recording, plus the pixel size and frame rate of the output.
struct CaptureSetup {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int
    let fps: Int

    /// Builds the filter and configuration for `target` with `CaptureTarget.streamSetup`.
    /// `overlays` (click highlights, keystrokes, webcam) are Screenme windows filmed on purpose.
    @MainActor
    static func make(for target: CaptureTarget, settings: RecordingSettings, overlays: [NSWindow]) async throws -> CaptureSetup {
        // GIFs are filmed at 1x: they end up small anyway.
        let (filter, config) = try await target.streamSetup(showsCursor: settings.showCursor, retina: settings.format != .gif,
                                                            including: overlays.map { CGWindowID($0.windowNumber) })
        var width = CGFloat(config.width)
        var height = CGFloat(config.height)
        let longest = max(width, height)
        if longest > 4096 {
            width *= 4096 / longest
            height *= 4096 / longest
        }
        // H.264 wants even dimensions.
        let pixelWidth = max(2, Int(width) & ~1)
        let pixelHeight = max(2, Int(height) & ~1)
        config.width = pixelWidth
        config.height = pixelHeight

        let fps = settings.format == .gif ? min(settings.fps, 30) : settings.fps
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB

        if settings.systemAudio && settings.format == .video {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }
        if settings.microphone && settings.format == .video && Permission.microphone.isGranted {
            config.captureMicrophone = true
            if !settings.microphoneID.isEmpty { config.microphoneCaptureDeviceID = settings.microphoneID }
        }
        return CaptureSetup(filter: filter, configuration: config, width: pixelWidth, height: pixelHeight, fps: fps)
    }
}
