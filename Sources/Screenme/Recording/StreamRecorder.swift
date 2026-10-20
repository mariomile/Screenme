import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - Stream setup

/// Everything ScreenCaptureKit needs for one recording, plus the pixel size of the output.
struct CaptureSetup {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int

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
        return CaptureSetup(filter: filter, configuration: config, width: pixelWidth, height: pixelHeight)
    }
}

// MARK: - Recorder

/// Writes an SCStream to an MP4 with AVAssetWriter, which is what makes pause possible:
/// while paused, samples are dropped and every later timestamp is shifted back by the pause length,
/// so the file is one seamless movie.
///
/// All mutable state lives on `queue`; ScreenCaptureKit delivers samples there too.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private let width: Int
    private let height: Int
    private let fps: Int
    private let quality: VideoQuality
    private let wantsSystemAudio: Bool
    private let wantsMicrophone: Bool

    /// Called once, on an arbitrary thread, when the stream or the writer fails.
    var onFailure: (@Sendable (Error) -> Void)?

    let queue = DispatchQueue(label: "dev.mariomiletta.screenme.recorder", qos: .userInitiated)
    private var stream: SCStream?

    // Queue-confined state.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var systemFormat: CMFormatDescription?
    private var micFormat: CMFormatDescription?
    private var firstVideo: CMSampleBuffer?
    private var latestVideo: CMSampleBuffer?
    private var sessionStarted = false
    private var offset = CMTime.zero
    private var activeFrom = CMTime.invalid
    private var pausedAt: CMTime?
    private var lastOutPTS = CMTime.invalid
    private var clockSkew = CMTime.zero
    private var stopped = false
    private var failed = false

    convenience init(url: URL, setup: CaptureSetup, settings: RecordingSettings) {
        self.init(url: url, width: setup.width, height: setup.height,
                  fps: settings.format == .gif ? min(settings.fps, 30) : settings.fps, quality: settings.quality,
                  systemAudio: setup.configuration.capturesAudio, microphone: setup.configuration.captureMicrophone)
    }

    init(url: URL, width: Int, height: Int, fps: Int, quality: VideoQuality, systemAudio: Bool, microphone: Bool) {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.quality = quality
        wantsSystemAudio = systemAudio
        wantsMicrophone = microphone
        super.init()
    }

    // MARK: Lifecycle

    func start(_ setup: CaptureSetup) async throws {
        let stream = SCStream(filter: setup.filter, configuration: setup.configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if wantsMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops the stream and finishes the file. Returns nil when nothing was recorded or `discard` is set.
    func finish(discard: Bool = false) async -> URL? {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        let written: URL? = await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true
                if !discard, !self.sessionStarted { self.startWriterIfReady(force: true) }
                guard !discard, !self.failed, self.sessionStarted, let writer = self.writer, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                let now = self.pausedAt ?? self.streamNow()
                var end = CMTimeSubtract(now, self.offset)
                if self.lastOutPTS.isValid, end < self.lastOutPTS { end = self.lastOutPTS }
                writer.endSession(atSourceTime: end)
                self.videoInput?.markAsFinished()
                self.systemInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? self.url : nil)
                }
            }
        }
        queue.async {
            self.firstVideo = nil
            self.latestVideo = nil
        }
        if written == nil || discard { try? FileManager.default.removeItem(at: url) }
        return discard ? nil : written
    }

    // MARK: Pause

    func pause() {
        queue.async {
            guard self.sessionStarted, self.pausedAt == nil else { return }
            self.pausedAt = self.streamNow()
        }
    }

    func resume() {
        queue.async {
            guard let pausedAt = self.pausedAt else { return }
            let now = self.streamNow()
            let pausedOffset = self.offset
            self.offset = CMTimeAdd(self.offset, CMTimeSubtract(now, pausedAt))
            self.pausedAt = nil
            self.activeFrom = now
            // Screens that stay still send no frames: show the newest picture right away.
            if let latest = self.latestVideo {
                let out = CMTimeSubtract(pausedAt, pausedOffset)
                self.appendVideo(latest, outputTime: out)
            }
        }
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        process(sampleBuffer, of: type)
    }

    /// Handles one sample on the calling queue. Split out so the pipeline can be fed without a stream.
    func process(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, !failed, sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, system: true)
        case .microphone: handleAudio(sampleBuffer, system: false)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopped else { return }
            self.fail(error)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isCompleteFrame(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp

        if !sessionStarted {
            if firstVideo == nil {
                firstVideo = sampleBuffer
                calibrateClock(with: pts)
                // Give the microphone a moment to deliver its first buffer so the file can match its format.
                queue.asyncAfter(deadline: .now() + 0.4) { self.startWriterIfReady(force: true) }
            }
            latestVideo = sampleBuffer
            startWriterIfReady(force: false)
            return
        }

        latestVideo = sampleBuffer
        if let pausedAt, pts >= pausedAt { return }
        if activeFrom.isValid, pts < activeFrom { return }
        appendVideo(sampleBuffer, outputTime: CMTimeSubtract(pts, offset))
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, system: Bool) {
        guard sampleBuffer.numSamples > 0 else { return }
        if !sessionStarted {
            if system, systemFormat == nil { systemFormat = sampleBuffer.formatDescription }
            if !system, micFormat == nil { micFormat = sampleBuffer.formatDescription }
            startWriterIfReady(force: false)
            return
        }
        guard let input = system ? systemInput : micInput else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let end = CMTimeAdd(pts, sampleBuffer.duration)
        if activeFrom.isValid, end <= activeFrom { return }
        if let pausedAt, pts >= pausedAt { return }
        guard input.isReadyForMoreMediaData, let shifted = sampleBuffer.shifted(by: offset) else { return }
        if !input.append(shifted) { checkWriter() }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, outputTime: CMTime) {
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        var out = outputTime
        if lastOutPTS.isValid, out <= lastOutPTS {
            out = CMTimeAdd(lastOutPTS, CMTime(value: 1, timescale: 1000))
        }
        let delta = CMTimeSubtract(sampleBuffer.presentationTimeStamp, out)
        guard let shifted = sampleBuffer.shifted(by: delta) else { return }
        if input.append(shifted) {
            lastOutPTS = out
        } else {
            checkWriter()
        }
    }

    // MARK: Writer

    /// Creates the writer once the first picture (and, if asked for, the first audio buffers) are in,
    /// so the audio tracks can be built from the real sample format.
    private func startWriterIfReady(force: Bool) {
        guard !sessionStarted, !failed, let first = firstVideo else { return }
        let waitingForSystem = wantsSystemAudio && systemFormat == nil
        let waitingForMic = wantsMicrophone && micFormat == nil
        if (waitingForSystem || waitingForMic) && !force { return }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: H264.settings(width: width, height: height, fps: fps,
                                                                                         quality: quality, realTime: true))
            video.expectsMediaDataInRealTime = true
            writer.add(video)
            if let format = systemFormat, wantsSystemAudio {
                let input = try audioInput(format)
                writer.add(input)
                systemInput = input
            }
            if let format = micFormat, wantsMicrophone {
                let input = try audioInput(format)
                writer.add(input)
                micInput = input
            }
            guard writer.startWriting() else { throw writer.error ?? ScreenmeError.recordingFailed }
            let start = first.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            self.writer = writer
            videoInput = video
            activeFrom = start
            sessionStarted = true

            appendVideo(first, outputTime: start)
            if let latest = latestVideo, latest.presentationTimeStamp > start {
                appendVideo(latest, outputTime: latest.presentationTimeStamp)
            }
            firstVideo = nil
        } catch {
            fail(error)
        }
    }

    private func audioInput(_ format: CMFormatDescription) throws -> AVAssetWriterInput {
        guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw ScreenmeError.recordingFailed
        }
        let channels = min(max(Int(description.mChannelsPerFrame), 1), 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(description.mSampleRate, 48000),
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func checkWriter() {
        if let writer, writer.status == .failed { fail(writer.error ?? ScreenmeError.recordingFailed) }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        onFailure?(error)
    }

    // MARK: Clock

    private func streamNow() -> CMTime {
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), clockSkew)
    }

    /// Stream timestamps normally share the host clock. If they do not, remember the difference.
    private func calibrateClock(with pts: CMTime) {
        let difference = CMTimeSubtract(pts, CMClockGetTime(CMClockGetHostTimeClock()))
        clockSkew = abs(difference.seconds) > 1 ? difference : .zero
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
