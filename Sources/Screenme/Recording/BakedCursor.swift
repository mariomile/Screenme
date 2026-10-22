import AVFoundation

/// A Smooth cursor recording is filmed without the cursor, and only the video editor draws it. Everything else
/// that takes the file (Quick Access Copy, Save and drag, History, Copy for AI) would get a video with no cursor,
/// so when the recording stops it is rendered once with the saved cursor style and no background or zoom, and
/// that file becomes the capture. Its events keep saying it was filmed without the cursor and add the style it was
/// drawn in (`CursorTrack.bakedStyle`). The raw recording stays next to it as a hidden source,
/// `.<capture>.screenme-source.mp4`, hidden like the events sidecar so History and the CLI never list it: the video
/// editor opens the source and draws the cursor again, so its style can still change.
enum BakedCursor {
    /// Where the cursorless recording of `capture` is kept.
    static func sourceURL(for capture: URL) -> URL {
        capture.deletingLastPathComponent().appendingPathComponent(".\(capture.lastPathComponent).screenme-source.mp4")
    }

    /// The capture went to the Trash: its source goes too.
    static func removeSource(for capture: URL) {
        try? FileManager.default.trashItem(at: sourceURL(for: capture), resultingItemURL: nil)
    }

    /// The cursorless recording `video` with the cursor drawn in `style`, and its events with that style; `video`
    /// becomes its hidden source. `events` must hold the cursor track of a recording filmed without the cursor.
    @MainActor
    static func render(_ video: URL, size: CGSize, events: RecordingEvents, style: CursorStyle,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> (url: URL, events: RecordingEvents) {
        let duration = try await AVURLAsset(url: video).load(.duration)
        var edit = VideoEdit()
        edit.cursor = style
        let renderer = edit.renderer(for: VideoSource(size: size, events: events),
                                     renderSize: ExportResolution.original.outputSize(for: size), duration: duration.seconds)
        let settings = VideoExportSettings(range: CMTimeRange(start: .zero, duration: duration), renderer: renderer,
                                           quality: .high, codec: Prefs[Pref.videoCodec], mute: false)
        let url = try await VideoTranscoder.export(video, settings: settings, progress: progress)
        do {
            try FileManager.default.moveItem(at: video, to: sourceURL(for: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        var baked = events
        baked.cursor?.bakedStyle = style
        return (url, baked)
    }
}
