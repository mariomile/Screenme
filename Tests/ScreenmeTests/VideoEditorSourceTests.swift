import AVFoundation
import XCTest
@testable import Screenme

/// A Smooth cursor capture has the cursor drawn in, and its cursorless source next to it. The video editor opens
/// the source, so the cursor can be restyled; a capture without a source keeps the cursor controls off. Done skips
/// the export only when the output would be the capture as it is.
final class VideoEditorSourceTests: PrefsSandboxTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup.removeAll()
        super.tearDown()
    }

    /// A capture with the events of a recording filmed without the cursor (`hidden`), drawn in `baked` when stopped.
    @MainActor
    private func capture(hidden: Bool = true, baked: CursorStyle?, codec: VideoCodec = .h264) async throws -> URL {
        var video = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        if codec == .hevc {
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
            let renderer = FrameRenderer(renderSize: CGSize(width: 320, height: 180))
            let hevc = try await VideoTranscoder.export(video, settings: VideoExportSettings(range: range, renderer: renderer, quality: .high,
                                                                                            codec: .hevc, mute: true))
            try FileManager.default.removeItem(at: video)
            video = hevc
        }
        cleanup += [video, RecordingEvents.sidecarURL(for: video), BakedCursor.sourceURL(for: video)]
        var events = RecordingEvents(width: 160, height: 90, events: [])
        var track = CursorTrack(hidden: hidden, bakedStyle: baked)
        track.add(time: 0, x: 40, y: 40)
        track.add(time: 1, x: 120, y: 60)
        events.cursor = track
        RecordingEvents.record(events, for: video)
        return video
    }

    @MainActor
    private func addSource(to capture: URL) async throws {
        let raw = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        try FileManager.default.moveItem(at: raw, to: BakedCursor.sourceURL(for: capture))
    }

    @MainActor
    private func loaded(_ url: URL) async throws -> VideoEditorModel {
        let model = VideoEditorModel(item: CaptureItem(url: url, kind: .video))
        for _ in 0..<200 where model.duration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(model.duration, 0)
        return model
    }

    @MainActor
    func testACaptureWithASourceOpensTheSourceWithTheCursorControlsOn() async throws {
        let style = CursorStyle(show: true, size: 2, clickHighlight: false, hideWhenIdle: false)
        CursorStyle.saved = style
        let capture = try await capture(baked: style)
        try await addSource(to: capture)

        let model = try await loaded(capture)

        XCTAssertEqual(model.videoURL, BakedCursor.sourceURL(for: capture), "plays and exports the cursorless source")
        XCTAssertEqual(model.item.url, capture, "the capture stays the item")
        XCTAssertNotNil(model.source.drawableCursor)
        XCTAssertTrue(model.edit.drawsCursor(for: model.source))
        XCTAssertTrue(model.isUnmodified, "the capture was drawn in the style the editor opened with")
        model.edit.cursor.size += 0.5
        XCTAssertFalse(model.isUnmodified, "a new cursor style needs an export from the source")
        model.edit.cursor.size -= 0.5
        XCTAssertTrue(model.isUnmodified, "back to the style the capture has")
        model.edit.cursor.show = false
        XCTAssertFalse(model.isUnmodified, "no cursor needs an export from the source")
    }

    /// Another editor saved a different cursor style since the capture was drawn: the capture still has its own.
    @MainActor
    func testTheCapturesOwnStyleDecidesNotTheSavedOne() async throws {
        let drawn = CursorStyle(show: true, size: 2.5, clickHighlight: true, hideWhenIdle: false)
        let capture = try await capture(baked: drawn)
        try await addSource(to: capture)
        CursorStyle.saved = CursorStyle(show: true, size: 1, clickHighlight: false, hideWhenIdle: true)

        let model = try await loaded(capture)

        XCTAssertEqual(model.edit.cursor, CursorStyle.saved, "the editor opens with the saved style")
        XCTAssertFalse(model.isUnmodified, "the saved style is not the one in the capture")
        model.edit.cursor = drawn
        XCTAssertTrue(model.isUnmodified, "the style drawn into the capture")
    }

    @MainActor
    func testACaptureWhoseSourceIsGoneKeepsItsCursor() async throws {
        let capture = try await capture(baked: CursorStyle())

        let model = try await loaded(capture)

        XCTAssertEqual(model.videoURL, capture)
        XCTAssertNil(model.source.drawableCursor, "the cursor is drawn into this file for good")
        XCTAssertTrue(model.isUnmodified)
    }

    @MainActor
    func testACaptureFilmedWithTheCursorKeepsTheCursorControlsOff() async throws {
        let capture = try await capture(hidden: false, baked: nil)

        let model = try await loaded(capture)

        XCTAssertEqual(model.videoURL, capture)
        XCTAssertNil(model.source.drawableCursor, "the cursor is part of this recording")
        XCTAssertTrue(model.isUnmodified)
    }

    /// The codec the editor exports in is a saved choice; Done skips the export when it matches the capture's codec.
    @MainActor
    func testAnHEVCCaptureIsUnmodifiedInHEVCOnly() async throws {
        Prefs[Pref.videoCodec] = .hevc
        let hevc = try await loaded(capture(hidden: false, baked: nil, codec: .hevc))
        XCTAssertEqual(hevc.codec, .hevc)
        XCTAssertTrue(hevc.isUnmodified, "an untouched HEVC capture is not encoded again")
        hevc.codec = .h264
        XCTAssertFalse(hevc.isUnmodified)

        Prefs[Pref.videoCodec] = .hevc
        let h264 = try await loaded(capture(hidden: false, baked: nil))
        XCTAssertFalse(h264.isUnmodified, "an H.264 capture exported as HEVC")
        h264.codec = .h264
        XCTAssertTrue(h264.isUnmodified)
    }
}
