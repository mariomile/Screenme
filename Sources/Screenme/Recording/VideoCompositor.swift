import AVFoundation
import CoreImage
import Metal

/// Draws one output frame of an edited video from one source frame, on the GPU with Core Image.
/// Built once per edit on the main actor and read from AVFoundation's threads, so it never changes after init.
/// The preview and every export use the same renderer, so what the editor shows is what gets exported.
final class FrameRenderer: @unchecked Sendable {
    /// Output pixels.
    let renderSize: CGSize
    /// Source time = `timeOffset + compositionTime * speed`: the trim start and the speed of an export.
    let timeOffset: Double
    let speed: Double
    /// Where the video lands, in output pixels with the origin bottom-left.
    let contentRect: CGRect
    /// The canvas behind the video with its shadow already painted; nil when the video fills the frame.
    let background: CIImage?
    /// White where the video shows (its rounded rectangle), transparent elsewhere; nil for square corners.
    let mask: CIImage?
    /// Zooms; nil shows the whole video all along.
    let camera: CameraPath?
    /// The smooth cursor, drawn on the recording before the zoom so it zooms with it.
    let cursor: CursorOverlay?

    init(renderSize: CGSize, timeOffset: Double = 0, speed: Double = 1, contentRect: CGRect? = nil,
         background: CIImage? = nil, mask: CIImage? = nil, camera: CameraPath? = nil, cursor: CursorOverlay? = nil) {
        self.cursor = cursor
        self.renderSize = renderSize
        self.timeOffset = timeOffset
        self.speed = speed
        self.contentRect = contentRect ?? CGRect(origin: .zero, size: renderSize)
        self.background = background
        self.mask = mask
        self.camera = camera
    }

    func sourceTime(at compositionTime: Double) -> Double { timeOffset + compositionTime * speed }

    /// The output frame for `source` (a frame of the recording, at its own pixel size) at `compositionTime`.
    func image(for source: CIImage, at compositionTime: Double) -> CIImage {
        let time = sourceTime(at: compositionTime)
        let extent = source.extent
        var visible = extent
        if let camera {
            // Unit coordinates from the top-left to pixels from the bottom-left.
            let rect = camera.camera(at: time).visibleRect
            visible = CGRect(x: extent.minX + rect.minX * extent.width, y: extent.minY + (1 - rect.maxY) * extent.height,
                             width: rect.width * extent.width, height: rect.height * extent.height)
        }
        let transform = CGAffineTransform(translationX: -visible.minX, y: -visible.minY)
            .concatenating(CGAffineTransform(scaleX: contentRect.width / visible.width, y: contentRect.height / visible.height))
            .concatenating(CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
        let picture = cursor?.draw(over: source, at: time) ?? source
        let video = picture.clampedToExtent().transformed(by: transform, highQualityDownsample: true).cropped(to: contentRect)
        guard let background else { return video }
        guard let mask else { return video.composited(over: background) }
        return video.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }
}

/// The one instruction of an edited video: the whole timeline, drawn by a `FrameRenderer`.
final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let renderer: FrameRenderer

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, renderer: FrameRenderer) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.renderer = renderer
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// The custom compositor AVFoundation runs for preview and export: one Core Image pass per frame on a Metal context,
/// straight into the pixel buffer the encoder reads.
final class FrameCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "Screenme video"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: ScreenmeError.recordingFailed)
            return
        }
        let image = instruction.renderer.image(for: CIImage(cvPixelBuffer: source), at: request.compositionTime.seconds)
        let size = request.renderContext.size
        Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}

/// The trimmed, sped up asset an export reads, and the video compositions that draw it.
enum EditedVideo {
    struct Source {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let audioTracks: [AVMutableCompositionTrack]
        let fps: Int

        /// The video track drawn by `renderer` over the whole composition.
        func videoComposition(_ renderer: FrameRenderer) -> AVMutableVideoComposition {
            EditedVideo.videoComposition(renderer: renderer, trackID: videoTrack.trackID, duration: composition.duration, fps: fps)
        }

        /// The drawn frames of `videoComposition`, in BGRA, for an `AVAssetReader` of `composition`.
        func drawnFrames(_ videoComposition: AVVideoComposition) -> AVAssetReaderVideoCompositionOutput {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.videoComposition = videoComposition
            output.alwaysCopiesSampleData = false
            return output
        }
    }

    /// The frame rate a video is drawn and encoded at: its own, between 24 and 60, or 30 when it does not say.
    static func frameRate(nominal: Float) -> Int {
        nominal > 1 ? Int(min(max(nominal, 24), 60).rounded()) : 30
    }

    /// `range` of the asset at `url` from time zero, played `speed` times faster, without sound when `mute` is set.
    static func source(_ url: URL, range: CMTimeRange, speed: Double, mute: Bool) async throws -> Source {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ScreenmeError.recordingFailed }
        let audio = mute ? [] : try await asset.loadTracks(withMediaType: .audio)
        let fps = try await frameRate(nominal: video.load(.nominalFrameRate))

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScreenmeError.recordingFailed
        }
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        var audioTracks: [AVMutableCompositionTrack] = []
        for track in audio {
            guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try added.insertTimeRange(range, of: track, at: .zero)
            audioTracks.append(added)
        }
        if abs(speed - 1) > 0.001 {
            let scaled = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / speed)
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: scaled)
        }
        return Source(composition: composition, videoTrack: videoTrack, audioTracks: audioTracks, fps: fps)
    }

    /// Draws the track `trackID` over `duration` with `renderer`, at `fps`.
    static func videoComposition(renderer: FrameRenderer, trackID: CMPersistentTrackID, duration: CMTime, fps: Int) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = FrameCompositor.self
        composition.renderSize = renderer.renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        composition.instructions = [FrameInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackID: trackID, renderer: renderer)]
        return composition
    }
}
