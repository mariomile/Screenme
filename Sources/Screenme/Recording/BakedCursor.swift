import AVFoundation

/// A Smooth cursor recording is filmed without the cursor, and only the video editor draws it. Everything else
/// that takes the file (Quick Access Copy, Save and drag, History, Copy for AI) would get a video with no cursor,
/// so when the recording stops it is rendered once with the saved cursor style and no background or zoom, and
/// that file becomes the capture. Its events say the cursor is in the picture. The raw recording stays next to it
/// as a hidden source, `.<capture>.screenme-source.mp4`, hidden like the events sidecar so History and the CLI
/// never list it: the video editor opens the source and draws the cursor again, so its style can still change.
enum BakedCursor {
    /// True when the recording left the cursor out of the picture and the user wants a cursor drawn.
    static func isNeeded(events: RecordingEvents?, style: CursorStyle) -> Bool {
        style.show && events?.cursor?.hidden == true
    }

    /// Where the cursorless recording of `capture` is kept.
    static func sourceURL(for capture: URL) -> URL {
        capture.deletingLastPathComponent().appendingPathComponent(".\(capture.lastPathComponent).screenme-source.mp4")
    }

    /// The cursorless recording of `capture`, or nil when the capture has none.
    static func source(for capture: URL) -> URL? {
        let url = sourceURL(for: capture)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The capture went to the Trash: its source goes too.
    static func removeSource(for capture: URL) {
        try? FileManager.default.trashItem(at: sourceURL(for: capture), resultingItemURL: nil)
    }

    /// The recording with the cursor drawn in, and its events marked accordingly; `video` becomes its hidden source.
    /// Nil when the cursor is not needed, and `video` is left as it is.
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
        do {
            try FileManager.default.moveItem(at: video, to: sourceURL(for: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // The capture's events describe the capture: the cursor is in its picture. The editor knows better from the source.
        var baked = events
        baked.cursor?.hidden = false
        return (url, baked)
    }
}
