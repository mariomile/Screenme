import AVFoundation

/// A Smooth cursor recording is filmed without the cursor, and only the video editor draws it. Everything else
/// that takes the file (Quick Access Copy, Save and drag, History, Copy for AI) would get a video with no cursor,
/// so when the recording stops it is rendered once with the saved cursor style and no background or zoom, and
/// that file becomes the capture. The raw file is deleted. The editor opens the rendered file: its events (clicks,
/// cursor path) are kept for auto zoom, but they say the cursor is in the picture, so the cursor controls are off.
enum BakedCursor {
    /// True when the recording left the cursor out of the picture and the user wants a cursor drawn.
    static func isNeeded(events: RecordingEvents?, style: CursorStyle) -> Bool {
        style.show && events?.cursor?.hidden == true
    }

    /// The recording with the cursor drawn in, and its events marked accordingly. Nil when the cursor is not needed.
    @MainActor
    static func render(_ video: URL, size: CGSize, events: RecordingEvents?, style: CursorStyle = .saved,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> (url: URL, events: RecordingEvents)? {
        guard let events, isNeeded(events: events, style: style) else { return nil }
        let duration = try await AVURLAsset(url: video).load(.duration)
        var edit = VideoEdit()
        edit.cursor = style
        let renderer = edit.renderer(for: VideoSource(size: size, events: events),
                                     renderSize: ExportResolution.original.outputSize(for: size), duration: duration.seconds)
        let settings = VideoExportSettings(range: CMTimeRange(start: .zero, duration: duration), renderer: renderer,
                                           quality: .high, codec: Prefs[Pref.videoCodec], mute: false)
        let url = try await VideoTranscoder.export(video, settings: settings, progress: progress)
        var baked = events
        baked.cursor?.hidden = false
        return (url, baked)
    }
}
