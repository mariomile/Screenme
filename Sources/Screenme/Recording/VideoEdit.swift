import AppKit
import CoreImage

/// The recording an edit is drawn from: its pixel size and, when it has them, its events (clicks, cursor).
struct VideoSource {
    var size: CGSize
    var events: RecordingEvents?
    /// The smoothed cursor track, worked out once.
    var cursor: CursorPath?

    init(size: CGSize, events: RecordingEvents?, cursor: CursorPath? = nil) {
        self.size = size
        self.events = events
        self.cursor = cursor ?? Self.cursorPath(of: events)
    }

    static func cursorPath(of events: RecordingEvents?) -> CursorPath? {
        guard let events, let track = events.cursor else { return nil }
        return CursorPath(track: track, width: events.width, height: events.height)
    }

    /// Video pixels per point of the recorded screen: 2 on a Retina display.
    var pixelsPerPoint: CGFloat {
        if let events, events.width > 0 { return size.width / events.width }
        return max(1, (size.width / 1600).rounded())
    }
}

/// Everything the video editor draws on top of the recording.
struct VideoEdit: Equatable {
    var canvas = BackgroundSettings()
    var zooms: [ZoomSegment] = []
    /// How far automatic zooms go in.
    var zoomStrength = 1.8

    /// True when the output is the recording's own picture, only trimmed or scaled.
    var isPlain: Bool { !canvas.enabled && zooms.isEmpty }

    /// The canvas the video sits on, in video pixels. Without a background, the video itself.
    func layout(for source: VideoSource) -> Layout {
        VideoCanvas.layout(videoSize: source.size, settings: canvas)
    }

    /// The pixel size of an export at `resolution`.
    func outputSize(for source: VideoSource, resolution: ExportResolution) -> CGSize {
        resolution.outputSize(for: layout(for: source).canvasSize)
    }

    /// The renderer for an output of `renderSize`. `timeOffset` and `speed` map export time to recording time;
    /// `duration` is the recording's, which the camera is worked out over. `zoomed` false shows the whole video.
    @MainActor
    func renderer(for source: VideoSource, renderSize: CGSize, duration: Double, timeOffset: Double = 0, speed: Double = 1,
                  zoomed: Bool = true) -> FrameRenderer {
        let layout = layout(for: source)
        let content = VideoCanvas.contentRect(layout, renderSize: renderSize)
        var background: CIImage?
        var mask: CIImage?
        if canvas.enabled {
            let unit = source.pixelsPerPoint * renderSize.width / layout.canvasSize.width
            background = VideoCanvas.backgroundImage(canvas, renderSize: renderSize, contentRect: content, unit: unit)
            mask = VideoCanvas.mask(contentRect: content, radius: VideoCanvas.cornerRadius(canvas, contentRect: content, unit: unit))
        }
        let camera = zoomed && !zooms.isEmpty
            ? CameraPath(segments: zooms, strength: zoomStrength, cursor: source.cursor, duration: duration) : nil
        return FrameRenderer(renderSize: renderSize, timeOffset: timeOffset, speed: speed, contentRect: content,
                             background: background, mask: mask, camera: camera)
    }
}
