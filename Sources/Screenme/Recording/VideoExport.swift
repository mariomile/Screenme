import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Shared helpers

/// A flag the export loops poll, so a cancelled Task stops the work running on other threads.
final class ExportCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// An RGBX bitmap that video frames are drawn (and scaled) into.
final class RGBAFrame {
    let width: Int
    let height: Int
    private let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
    }

    var pixels: UnsafePointer<UInt8> { UnsafePointer(context.data!.assumingMemoryBound(to: UInt8.self)) }
    var bytesPerRow: Int { context.bytesPerRow }

    func draw(_ image: CGImage) {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func draw(_ pixelBuffer: CVPixelBuffer) {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        if let image { draw(image) }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case original, p1080, p720, p480

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    /// The short side the output is scaled down to; nil keeps the source size.
    var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    /// `size` scaled down to at most `maxWidth` pixels wide (0: any width), for GIFs. Never scales up; dimensions are even.
    static func fitting(_ size: CGSize, maxWidth: Int) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let scale = maxWidth > 0 ? min(1, CGFloat(maxWidth) / size.width) : 1
        return CGSize(width: max(2, Int((size.width * scale).rounded()) & ~1), height: max(2, Int((size.height * scale).rounded()) & ~1))
    }

    /// The output size for a source of `size`. Never scales up; dimensions are even.
    func outputSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var scale: CGFloat = 1
        if let shortSide { scale = min(1, shortSide / min(size.width, size.height)) }
        let width = max(2, Int((size.width * scale).rounded()) & ~1)
        let height = max(2, Int((size.height * scale).rounded()) & ~1)
        return CGSize(width: width, height: height)
    }
}

// MARK: - GIF

/// Converts video to an animated GIF with a shared adaptive palette, ordered dithering,
/// changed-rectangle frames and an infinite loop.
enum GIFExporter {
    /// Converts the edit drawn by `renderer` (`range` of the video at `url`) to a GIF of the renderer's size at `fps`
    /// (at most 30). `quality` sets the palette size and the dithering.
    static func export(_ url: URL, range: CMTimeRange, renderer: FrameRenderer, fps: Int, quality: VideoQuality,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let source = try await EditedVideo.source(url, range: range, speed: renderer.speed, mute: true)
        let composition = source.videoComposition(renderer)
        let width = max(2, Int(renderer.renderSize.width.rounded()))
        let height = max(2, Int(renderer.renderSize.height.rounded()))
        let rate = Double(min(max(fps, 1), 30))
        let colors = quality.gifColors
        let dither = quality.gifDither

        let cancel = ExportCancel()
        let output = Storage.newURL(extension: "gif")
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try await encode(source: source, composition: composition, width: width, height: height, fps: rate,
                                     colors: colors, dither: dither, output: output, cancel: cancel, progress: progress)
                }.value
            } onCancel: {
                cancel.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return output
    }

    /// Streams the GIF to `url` as frames are made.
    private static func encode(source: EditedVideo.Source, composition: AVVideoComposition, width: Int, height: Int, fps: Double,
                               colors: Int, dither: Bool, output url: URL, cancel: ExportCancel,
                               progress: @Sendable (Double) -> Void) async throws {
        let asset = source.composition
        let frame = RGBAFrame(width: width, height: height)
        let total = max(asset.duration.seconds, 0.04)

        // Pass 1: a palette from a dozen frames spread over the clip.
        let builder = GIFPaletteBuilder()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: width, height: height)
        let samples = 12
        for index in 0..<samples {
            try cancel.check()
            let time = CMTime(seconds: total * (Double(index) + 0.5) / Double(samples), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                frame.draw(image)
                builder.add(frame.pixels, width: width, height: height, bytesPerRow: frame.bytesPerRow)
            }
        }
        let palette = builder.build(colors: colors)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ScreenmeError.recordingFailed }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = GIFEncoder(width: width, height: height, palette: palette, dither: dither, output: handle)

        // Pass 2: read every drawn frame in order and hold each one until the next tick of the GIF clock.
        let reader = try AVAssetReader(asset: asset)
        let output = source.drawnFrames(composition)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ScreenmeError.recordingFailed }

        let step = 1 / fps
        var tick = 0.0
        var held: CMSampleBuffer?
        var heldDrawn = false
        var changed = false
        var emitted = 0

        func emitTicks(before limit: Double) {
            while tick < limit - 1e-6, tick < total {
                if let sample = held {
                    if !heldDrawn, let buffer = CMSampleBufferGetImageBuffer(sample) {
                        frame.draw(buffer)
                        heldDrawn = true
                        changed = true
                    }
                    if changed || emitted == 0 {
                        encoder.add(frame.pixels, bytesPerRow: frame.bytesPerRow, at: tick)
                        emitted += 1
                        changed = false
                    }
                }
                tick += step
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            if cancel.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let time = sample.presentationTimeStamp.seconds
            emitTicks(before: time)
            held = sample
            heldDrawn = false
            progress(min(max(time / total, 0), 1) * 0.97)
        }
        if reader.status == .failed { throw reader.error ?? ScreenmeError.recordingFailed }
        emitTicks(before: total)
        guard emitted > 0 else { throw ScreenmeError.recordingFailed }
        try encoder.finishFile(endTime: total)
    }
}

// MARK: - MP4

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc

    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var type: AVVideoCodecType { self == .h264 ? .h264 : .hevc }

    /// The codec of a video track's format, by its media subtype. Nil for any other codec.
    init?(subtype: FourCharCode) {
        switch subtype {
        case kCMVideoCodecType_H264: self = .h264
        case kCMVideoCodecType_HEVC: self = .hevc
        default: return nil
        }
    }
}

struct VideoExportSettings {
    /// The part of the recording to export, in its own time.
    var range: CMTimeRange
    /// Draws every frame: its size is the output size and its speed the playback speed.
    var renderer: FrameRenderer
    var quality: VideoQuality
    var codec = VideoCodec.h264
    var mute: Bool
}

/// Trims, speeds up, draws and encodes a video to MP4 in one pass: AVAssetReader through the `FrameCompositor`
/// on the GPU, then the hardware encoder through AVAssetWriter. Multiple audio tracks (system audio and
/// microphone) are mixed into one.
enum VideoTranscoder {
    static func export(_ url: URL, settings: VideoExportSettings, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let source = try await EditedVideo.source(url, range: settings.range, speed: settings.renderer.speed, mute: settings.mute)
        let job = try TranscodeJob(source: source, settings: settings, progress: progress)
        return try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }
}

private final class TranscodeJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var audioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let duration: Double
    private let cancelFlag = ExportCancel()
    private let progress: (@Sendable (Double) -> Void)?

    init(source: EditedVideo.Source, settings: VideoExportSettings, progress: (@Sendable (Double) -> Void)?) throws {
        self.progress = progress
        let asset = source.composition
        duration = max(asset.duration.seconds, 0.04)
        outputURL = Storage.newURL(extension: "mp4")
        let size = settings.renderer.renderSize

        reader = try AVAssetReader(asset: asset)
        videoOutput = source.drawnFrames(source.videoComposition(settings.renderer))
        reader.add(videoOutput)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video,
                                        outputSettings: H264.settings(width: Int(size.width), height: Int(size.height), fps: source.fps,
                                                                      quality: settings.quality, realTime: false, codec: settings.codec))
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        if !source.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: source.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            // Sped up speech keeps its pitch.
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
    }

    func cancel() { cancelFlag.cancel() }

    func run() async throws -> URL {
        guard reader.startReading() else { throw reader.error ?? ScreenmeError.recordingFailed }
        guard writer.startWriting() else { throw writer.error ?? ScreenmeError.recordingFailed }
        writer.startSession(atSourceTime: .zero)

        let videoOutput = videoOutput, duration = duration, progress = progress
        var tracks = [MediaPump.Track(input: videoInput, label: "video", next: { videoOutput.copyNextSampleBuffer() },
                                      appended: { progress?(min(max($0.presentationTimeStamp.seconds / duration, 0), 1) * 0.99) })]
        if let audioOutput, let audioInput {
            tracks.append(MediaPump.Track(input: audioInput, label: "audio", next: { audioOutput.copyNextSampleBuffer() }))
        }
        await MediaPump.run(tracks, writer: writer) { [self] in cancelFlag.isCancelled || reader.status == .failed }

        if cancelFlag.isCancelled || reader.status == .failed || writer.status != .writing {
            let error = cancelFlag.isCancelled ? CancellationError() : (reader.error ?? writer.error ?? ScreenmeError.recordingFailed)
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            let error = writer.error ?? ScreenmeError.recordingFailed
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        progress?(1)
        return outputURL
    }
}

/// Feeds a writer's inputs, each from its own source on its own queue, until every one is done: its source ran dry,
/// an append failed, or `stopped` turned true. An input waiting for room is never called again once the writer has
/// failed or been cancelled, so a watchdog checks the writer and `stopped` every 100 ms and ends whatever still waits.
enum MediaPump {
    struct Track {
        var input: AVAssetWriterInput
        var label: String
        /// The next sample; nil when there are no more.
        var next: () -> CMSampleBuffer?
        /// Called after each sample is appended.
        var appended: (CMSampleBuffer) -> Void = { _ in }
    }

    static func run(_ tracks: [Track], writer: AVAssetWriter, stopped: @escaping @Sendable () -> Bool = { false }) async {
        let group = DispatchGroup()
        let ends = tracks.map { feed($0, group: group, stopped: stopped) }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        watchdog.setEventHandler {
            guard writer.status != .writing || stopped() else { return }
            ends.forEach { $0() }
            watchdog.cancel()
        }
        watchdog.resume()
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
        watchdog.cancel()
    }

    /// Starts feeding `track` and returns what ends it early, safe from any thread and more than once.
    private static func feed(_ track: Track, group: DispatchGroup, stopped: @escaping @Sendable () -> Bool) -> () -> Void {
        group.enter()
        let queue = DispatchQueue(label: "dev.mariomiletta.screenme.export." + track.label)
        var finished = false
        // On `queue`. Ended from outside, the writer has stopped, so the input is not marked finished.
        func finish(markingInput: Bool) {
            guard !finished else { return }
            finished = true
            if markingInput { track.input.markAsFinished() }
            group.leave()
        }
        track.input.requestMediaDataWhenReady(on: queue) {
            while track.input.isReadyForMoreMediaData, !finished {
                guard !stopped(), let sample = track.next(), track.input.append(sample) else { return finish(markingInput: true) }
                track.appended(sample)
            }
        }
        return { queue.async { finish(markingInput: false) } }
    }
}
