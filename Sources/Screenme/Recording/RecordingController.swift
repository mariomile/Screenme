import AppKit
import AVFoundation
import ScreenCaptureKit

/// Screen recording to MP4 through ScreenCaptureKit's built-in recording output.
@MainActor
final class RecordingController: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = RecordingController()

    private var stream: SCStream?
    private var url: URL?
    private var outline: NSPanel?
    private var finished: CheckedContinuation<Void, Never>?

    var isRecording: Bool { stream != nil }

    @MainActor
    func start(_ target: CaptureTarget) async throws {
        let (filter, config) = try await target.streamSetup()
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6

        let url = Storage.newURL(extension: "mp4")
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: outputConfig, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        self.url = url
        AppState.shared.isRecording = true
        showOutline(around: target.cocoaFrame)
    }

    /// Stops the stream and returns the finished file once it is fully written.
    @MainActor
    func stop() async -> CaptureItem? {
        guard let stream else { return nil }
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { try? await stream.stopCapture() }
        }
        self.stream = nil
        AppState.shared.isRecording = false
        outline?.orderOut(nil)
        outline = nil
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return CaptureItem(url: url, kind: .video)
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resume()
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resume()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        resume()
    }

    nonisolated private func resume() {
        Task { @MainActor in
            self.finished?.resume()
            self.finished = nil
        }
    }

    /// A thin red frame around the recorded area. Screenme's windows are excluded from capture.
    private func showOutline(around frame: CGRect) {
        let rect = frame.insetBy(dx: -2, dy: -2)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let border = NSView(frame: CGRect(origin: .zero, size: rect.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.cgColor
        border.layer?.borderWidth = 2
        panel.contentView = border
        panel.orderFrontRegardless()
        outline = panel
    }
}
