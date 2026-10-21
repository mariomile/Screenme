import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Writes an SCStream to an MP4 with AVAssetWriter, which is what makes pause possible:
/// `PauseTimeline` drops what is captured while paused and moves every later sample back by the pause length.
///
/// All mutable state lives on `queue`; ScreenCaptureKit delivers samples there too.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private(set) var setup: CaptureSetup

    /// Called on an arbitrary thread when the stream stops on its own or the writer fails.
    var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "dev.mariomiletta.screenme.recorder", qos: .userInitiated)
    private var stream: SCStream?
    /// One writer input per stream output, in track order. The audio formats are fixed: the writer converts
    /// whatever the device delivers, so the file can be set up before the first sample arrives.
    private let tracks: [(type: SCStreamOutputType, input: AVAssetWriterInput)]

    private enum Phase {
        case awaitingFirstFrame
        case writing(AVAssetWriter)
        case finished
        case failed
    }

    // Queue-confined state.
    private var phase = Phase.awaitingFirstFrame
    private var timeline = PauseTimeline(start: .zero)
    /// The newest picture, shown again on resume: screens that stay still send no frames.
    private var latestVideo: CMSampleBuffer?
    /// Where each track's last sample ended in the file.
    private var trackEnds: [SCStreamOutputType: CMTime] = [:]

    init(url: URL, setup: CaptureSetup, quality: VideoQuality) {
        self.url = url
        self.setup = setup
        var tracks: [(SCStreamOutputType, AVAssetWriterInput)] = [
            (.screen, AVAssetWriterInput(mediaType: .video, outputSettings: H264.settings(width: setup.width, height: setup.height,
                                                                                        fps: setup.fps, quality: quality, realTime: true))),
        ]
        if setup.configuration.capturesAudio { tracks.append((.audio, Self.audioInput(channels: 2))) }
        if setup.configuration.captureMicrophone { tracks.append((.microphone, Self.audioInput(channels: 1))) }
        tracks.forEach { $0.1.expectsMediaDataInRealTime = true }
        self.tracks = tracks
        super.init()
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
    }

    // MARK: Lifecycle

    func start() async throws {
        let stream = SCStream(filter: setup.filter, configuration: setup.configuration, delegate: self)
        for track in tracks { try stream.addStreamOutput(self, type: track.type, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Films something else from now on, at the same output size: a window recording that starts filming the
    /// drawing overlay. Read from and called on the main actor only, like `start`.
    func film(_ newSetup: CaptureSetup) async throws {
        newSetup.configuration.width = setup.width
        newSetup.configuration.height = setup.height
        try await stream?.updateConfiguration(newSetup.configuration)
        try await stream?.updateContentFilter(newSetup.filter)
        setup = CaptureSetup(filter: newSetup.filter, configuration: newSetup.configuration,
                             width: setup.width, height: setup.height, fps: setup.fps)
    }

    /// Stops the stream and finishes the file. Returns nil when nothing was recorded or `discard` is set.
    func finish(discard: Bool = false) async -> URL? {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        let written: URL? = await withCheckedContinuation { continuation in
            queue.async {
                let phase = self.phase
                self.phase = .finished
                self.latestVideo = nil
                guard case .writing(let writer) = phase else {
                    continuation.resume(returning: nil)
                    return
                }
                guard !discard, writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                var end = self.timeline.end(at: Self.now())
                if let last = self.trackEnds[.screen], end < last { end = last }
                writer.endSession(atSourceTime: end)
                self.tracks.forEach { $0.input.markAsFinished() }
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? self.url : nil)
                }
            }
        }
        if written == nil { try? FileManager.default.removeItem(at: url) }
        return written
    }

    // MARK: Pause

    func pause() {
        queue.async {
            guard case .writing = self.phase else { return }
            self.timeline.pause(at: Self.now())
        }
    }

    func resume() {
        queue.async {
            guard case .writing = self.phase, self.timeline.isPaused else { return }
            let now = Self.now()
            let seam = self.timeline.end(at: now)
            self.timeline.resume(at: now)
            if let latest = self.latestVideo { self.append(latest, of: .screen, at: seam) }
        }
    }

    /// Seconds into the video of what happens now, for the recording's events: 0 before the first picture,
    /// nil while paused and once the recording is over.
    func videoTime() -> Double? {
        let now = Self.now()
        return queue.sync {
            switch phase {
            case .awaitingFirstFrame: 0
            case .writing: timeline.videoSeconds(at: now)
            case .finished, .failed: nil
            }
        }
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            guard isCompleteFrame(sampleBuffer) else { return }
        } else {
            guard sampleBuffer.numSamples > 0 else { return }
        }
        switch phase {
        case .awaitingFirstFrame:
            if type == .screen { begin(with: sampleBuffer) }
        case .writing:
            if type == .screen { latestVideo = sampleBuffer }
            let duration = type == .screen ? CMTime.zero : sampleBuffer.duration
            guard let time = timeline.outputTime(for: sampleBuffer.presentationTimeStamp, duration: duration) else { return }
            append(sampleBuffer, of: type, at: time)
        case .finished, .failed:
            break
        }
    }

    /// The file written so far is still good: report it and leave the writer open, so `finish` keeps the take.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }

    /// Starts the file at the first picture. Audio captured before it is dropped.
    private func begin(with first: CMSampleBuffer) {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            tracks.forEach { writer.add($0.input) }
            guard writer.startWriting() else { throw writer.error ?? ScreenmeError.recordingFailed }
            let start = first.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            phase = .writing(writer)
            timeline = PauseTimeline(start: start)
            latestVideo = first
            append(first, of: .screen, at: start)
        } catch {
            fail(error)
        }
    }

    /// Writes `sample` at file time `time`. Each track moves forward only: a picture that would land on or
    /// before the previous one is nudged after it; audio that would repeat more than half a buffer is dropped.
    /// Smaller audio overlaps are normal: device clocks drift against the host clock and timestamps round.
    private func append(_ sample: CMSampleBuffer, of type: SCStreamOutputType, at time: CMTime) {
        guard let input = tracks.first(where: { $0.type == type })?.input, input.isReadyForMoreMediaData else { return }
        var time = time
        if let last = trackEnds[type] {
            if type == .screen, time <= last {
                time = CMTimeAdd(last, CMTime(value: 1, timescale: 1000))
            } else if type != .screen, CMTimeSubtract(last, time) > CMTimeMultiplyByRatio(sample.duration, multiplier: 1, divisor: 2) {
                return
            }
        }
        guard let moved = sample.shifted(by: CMTimeSubtract(sample.presentationTimeStamp, time)) else { return }
        guard input.append(moved) else { return checkWriter() }
        trackEnds[type] = type == .screen ? time : CMTimeAdd(time, sample.duration)
    }

    private func checkWriter() {
        if case .writing(let writer) = phase, writer.status == .failed { fail(writer.error ?? ScreenmeError.recordingFailed) }
    }

    private func fail(_ error: Error) {
        switch phase {
        case .failed, .finished: return
        case .writing(let writer): writer.cancelWriting()
        case .awaitingFirstFrame: break
        }
        phase = .failed
        latestVideo = nil
        onFailure?(error)
    }

    /// ScreenCaptureKit stamps samples with `SCStream.synchronizationClock`, which is the host time clock.
    private static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
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
