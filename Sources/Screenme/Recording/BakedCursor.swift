import AVFoundation

/// A Smooth cursor recording is filmed without the cursor, and only the video editor draws it. Everything else
/// that takes the file (Quick Access Copy, Save and drag, History, Copy for AI) would get a video with no cursor,
/// so when the recording stops it is rendered once with the saved cursor style and no background or zoom, and
/// that file becomes the capture. Its events keep saying it was filmed without the cursor and add the style it was
/// drawn in (`CursorTrack.bakedStyle`). The raw recording stays next to it as a hidden source,
/// `.<capture>.screenme-source.mp4`, hidden like the events sidecar so History and the CLI never list it: the video
/// editor opens the source and draws the cursor again, so its style can still change.
enum BakedCursor {
    /// The cursorless recording `video` (`size` pixels) with the cursor drawn in `style`, written as `spec`, and
    /// its events with that style; `video` becomes its hidden source. `events` hold the recording's cursor track.
    @MainActor
    static func render(_ video: URL, size: CGSize, events: RecordingEvents, style: CursorStyle, spec: ExportSpec,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (item: CaptureItem, events: RecordingEvents) {
        var edit = VideoEdit()
        edit.cursor = style
        let item = try await VideoOutput.render(video, source: VideoSource(size: size, events: events, cursorless: true), edit: edit,
                                                spec: spec, progress: progress)
        do {
            try FileManager.default.moveItem(at: video, to: Sidecar.source.url(for: item.url))
        } catch {
            try? FileManager.default.removeItem(at: item.url)
            throw error
        }
        var baked = events
        baked.cursor?.bakedStyle = style
        return (item, baked)
    }
}
