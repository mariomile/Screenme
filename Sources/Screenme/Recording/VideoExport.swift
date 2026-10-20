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
    /// - Parameters:
    ///   - range: the part of the video to convert; all of it by default.
    ///   - outputSize: exact pixel size; otherwise the video is scaled down to `maxWidth`.
    static func export(_ url: URL, range: CMTimeRange? = nil, fps: Double = 15, maxWidth: CGFloat = 960,
                       outputSize: CGSize? = nil, colors: Int = 255, dither: Bool = true,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScreenmeError.recordingFailed }
        let natural = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
        let source = CGSize(width: abs(natural.width), height: abs(natural.height))
        let duration = try await asset.load(.duration)
        let clip = range ?? CMTimeRange(start: .zero, duration: duration)

        var size = outputSize ?? source
        if outputSize == nil, source.width > maxWidth {
            size = CGSize(width: maxWidth, height: (source.height * maxWidth / source.width).rounded())
        }
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        let rate = min(max(fps, 1), 30)

        let cancel = ExportCancel()
        let data: Data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try await encode(asset: asset, track: track, range: clip, width: width, height: height, fps: rate,
                                 colors: colors, dither: dither, cancel: cancel, progress: progress)
            }.value
        } onCancel: {
            cancel.cancel()
        }

        let output = Storage.newURL(extension: "gif")
        try data.write(to: output)
        progress?(1)
        return output
    }

    private static func encode(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, width: Int, height: Int, fps: Double,
                               colors: Int, dither: Bool, cancel: ExportCancel,
                               progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        let frame = RGBAFrame(width: width, height: height)
        let start = range.start.seconds
        let total = max(range.duration.seconds, 0.04)

        // Pass 1: a palette from a dozen frames spread over the clip.
        let builder = GIFPaletteBuilder()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: height)
        let samples = 12
        for index in 0..<samples {
            try cancel.check()
            let time = CMTime(seconds: start + total * (Double(index) + 0.5) / Double(samples), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                frame.draw(image)
                builder.add(frame.pixels, width: width, height: height, bytesPerRow: frame.bytesPerRow)
            }
        }
        let palette = builder.build(colors: colors)
        let encoder = GIFEncoder(width: width, height: height, palette: palette, dither: dither)

        // Pass 2: read every frame in order and hold each one until the next tick of the GIF clock.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        output.alwaysCopiesSampleData = false
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
            try cancel.check()
            let time = sample.presentationTimeStamp.seconds - start
            emitTicks(before: time)
            held = sample
            heldDrawn = false
            progress?(min(max(time / total, 0), 1) * 0.97)
        }
        if reader.status == .failed { throw reader.error ?? ScreenmeError.recordingFailed }
        emitTicks(before: total)
        guard emitted > 0 else { throw ScreenmeError.recordingFailed }
        return encoder.finish(endTime: total)
    }
}

// MARK: - MP4

struct VideoExportSettings {
    var range: CMTimeRange
    var size: CGSize
    var quality: String
    var mute: Bool
}

/// Trims, scales and re-encodes a video to MP4 with AVAssetReader and AVAssetWriter.
/// Multiple audio tracks (system audio and microphone) are mixed into one.
enum VideoTranscoder {
    static func export(_ url: URL, settings: VideoExportSettings, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ScreenmeError.recordingFailed }
        let audioTracks = settings.mute ? [] : try await asset.loadTracks(withMediaType: .audio)
        let nominal = try await videoTrack.load(.nominalFrameRate)
        let fps = nominal > 1 ? min(max(Double(nominal), 24), 60) : 30

        let job = try TranscodeJob(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks, settings: settings, fps: fps, progress: progress)
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
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var audioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let start: CMTime
    private let duration: Double
    private let cancelFlag = ExportCancel()
    private let progress: (@Sendable (Double) -> Void)?

    init(asset: AVURLAsset, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack], settings: VideoExportSettings,
         fps: Double, progress: (@Sendable (Double) -> Void)?) throws {
        self.progress = progress
        start = settings.range.start
        duration = max(settings.range.duration.seconds, 0.04)
        outputURL = Storage.newURL(extension: "mp4")

        reader = try AVAssetReader(asset: asset)
        reader.timeRange = settings.range
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = settings.size.width * settings.size.height * fps * RecordingSettings.bitsPerPixel(quality: settings.quality)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(settings.size.width),
            AVVideoHeightKey: Int(settings.size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(min(max(bitrate, 500_000), 80_000_000)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
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

        let group = DispatchGroup()
        pump(output: videoOutput, input: videoInput, label: "video", group: group, reportsProgress: true)
        if let audioOutput, let audioInput {
            pump(output: audioOutput, input: audioInput, label: "audio", group: group, reportsProgress: false)
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if cancelFlag.isCancelled || reader.status == .failed || writer.status == .failed {
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

    private func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, group: DispatchGroup, reportsProgress: Bool) {
        group.enter()
        let queue = DispatchQueue(label: "dev.mariomiletta.screenme.export.\(label)")
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData, !finished {
                guard !cancelFlag.isCancelled, let sample = output.copyNextSampleBuffer() else {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                // Timestamps start at zero; the sample that straddles the trim start is pinned to zero.
                let pts = sample.presentationTimeStamp
                let shifted = CMTimeMaximum(CMTimeSubtract(pts, start), .zero)
                guard let moved = sample.shifted(by: CMTimeSubtract(pts, shifted)) else { continue }
                if !input.append(moved) {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                if reportsProgress { progress?(min(max(shifted.seconds / duration, 0), 1) * 0.99) }
            }
        }
    }
}
