import AVFoundation
import XCTest
@testable import Screenme

/// A Smooth cursor capture has the cursor drawn in, and its cursorless source next to it. The video editor opens
/// the source, so the cursor can be restyled; a capture without a source keeps the cursor controls off.
final class VideoEditorSourceTests: PrefsSandboxTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup.removeAll()
        super.tearDown()
    }

    /// A capture whose events say the cursor is in the picture, as a rendered Smooth cursor recording's do.
    @MainActor
    private func capture() async throws -> URL {
        let video = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        cleanup += [video, RecordingEvents.sidecarURL(for: video), BakedCursor.sourceURL(for: video)]
        var events = RecordingEvents(width: 160, height: 90, events: [])
        var track = CursorTrack(hidden: false)
        track.add(time: 0, x: 40, y: 40)
        track.add(time: 1, x: 120, y: 60)
        events.cursor = track
        RecordingEvents.record(events, for: video)
        return video
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
        let capture = try await capture()
        let raw = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        try FileManager.default.moveItem(at: raw, to: BakedCursor.sourceURL(for: capture))

        let model = try await loaded(capture)

        XCTAssertEqual(model.videoURL, BakedCursor.sourceURL(for: capture), "plays and exports the cursorless source")
        XCTAssertEqual(model.item.url, capture, "the capture stays the item")
        XCTAssertTrue(model.canDrawCursor)
        XCTAssertTrue(model.edit.drawsCursor(for: model.source))
        XCTAssertTrue(model.isUnmodified, "the capture was rendered in the style the editor opened with")
        model.edit.cursor.size += 0.5
        XCTAssertFalse(model.isUnmodified, "a new cursor style needs an export from the source")
        model.edit.cursor.size -= 0.5
        XCTAssertTrue(model.isUnmodified, "back to the style the capture has")
        model.edit.cursor.show = false
        XCTAssertFalse(model.isUnmodified, "no cursor needs an export from the source")
    }

    @MainActor
    func testACaptureWithoutASourceKeepsTheCursorControlsOff() async throws {
        let capture = try await capture()

        let model = try await loaded(capture)

        XCTAssertEqual(model.videoURL, capture)
        XCTAssertFalse(model.canDrawCursor, "the cursor is part of this recording")
        XCTAssertTrue(model.isUnmodified)
    }
}
