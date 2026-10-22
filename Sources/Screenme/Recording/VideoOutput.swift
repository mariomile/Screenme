import AVFoundation

/// What a recording is written out as: an MP4 in a codec, quality and resolution, with or without its sound, or a
/// looping GIF at a frame rate, at most `maxWidth` pixels wide (0: any width).
enum ExportSpec: Equatable {
    case mp4(codec: VideoCodec, quality: VideoQuality, resolution: ExportResolution, mute: Bool)
    case gif(fps: Int, maxWidth: Int, quality: VideoQuality)

    /// The pixel size of the output for an edit whose canvas is `canvas` pixels. Never scales up; dimensions are even.
    func outputSize(for canvas: CGSize) -> CGSize {
        switch self {
        case .mp4(_, _, let resolution, _): resolution.outputSize(for: canvas)
        case .gif(_, let maxWidth, _): ExportResolution.fitting(ExportResolution.original.outputSize(for: canvas), maxWidth: maxWidth)
        }
    }
}

/// The one way a recording becomes a new file: the video editor's export, the cursor drawn into a Smooth cursor
/// recording, and a GIF recording's conversion when it stops.
enum VideoOutput {
    /// `range` of the video at `url` (all of it by default), drawn with `edit` over `source` and written as `spec` says.
    @MainActor
    static func render(_ url: URL, source: VideoSource, edit: VideoEdit, range: CMTimeRange? = nil, spec: ExportSpec,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CaptureItem {
        let duration = try await AVURLAsset(url: url).load(.duration)
        let range = range ?? CMTimeRange(start: .zero, duration: duration)
        let renderer = edit.renderer(for: source, renderSize: spec.outputSize(for: edit.layout(for: source).canvasSize),
                                     duration: duration.seconds, timeOffset: range.start.seconds, speed: edit.speed)
        switch spec {
        case .mp4(let codec, let quality, _, let mute):
            let settings = VideoExportSettings(range: range, renderer: renderer, quality: quality, codec: codec, mute: mute)
            return CaptureItem(url: try await VideoTranscoder.export(url, settings: settings, progress: progress), kind: .video)
        case .gif(let fps, _, let quality):
            let gif = try await GIFExporter.export(url, range: range, renderer: renderer, fps: fps, quality: quality, progress: progress)
            return CaptureItem(url: gif, kind: .gif)
        }
    }

    /// A progress callback for work on other threads that hands each value to `update` on the main actor.
    static func onMain(_ update: @escaping @MainActor @Sendable (Double) -> Void) -> @Sendable (Double) -> Void {
        { value in Task { @MainActor in update(value) } }
    }
}
