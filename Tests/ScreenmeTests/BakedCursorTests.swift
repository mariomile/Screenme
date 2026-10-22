import AVFoundation
import XCTest
@testable import Screenme

/// A Smooth cursor recording gets its cursor drawn into the file when it stops, so Copy, Save and drag are right,
/// and keeps the cursorless recording as a hidden source so the video editor can restyle the cursor.
final class BakedCursorTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup.removeAll()
        super.tearDown()
    }

    private func events(hidden: Bool, withTrack: Bool = true) -> RecordingEvents {
        var events = RecordingEvents(width: 200, height: 100, events: [])
        if withTrack {
            var track = CursorTrack(hidden: hidden)
            track.add(time: 0, x: 50, y: 60)
            track.add(time: 2, x: 50, y: 60)
            events.cursor = track
        }
        return events
    }

    func testOnlyARecordingMadeWithoutTheCursorNeedsItDrawn() {
        let style = CursorStyle()
        XCTAssertTrue(BakedCursor.isNeeded(events: events(hidden: true), style: style))
        XCTAssertFalse(BakedCursor.isNeeded(events: events(hidden: false), style: style), "the cursor is in the picture")
        XCTAssertFalse(BakedCursor.isNeeded(events: events(hidden: true, withTrack: false), style: style), "no cursor track")
        XCTAssertFalse(BakedCursor.isNeeded(events: nil, style: style), "no events")
        XCTAssertFalse(BakedCursor.isNeeded(events: events(hidden: true), style: CursorStyle(show: false)), "the user hides the cursor")
    }

    @MainActor
    func testStoppingRendersTheCaptureAndKeepsTheCursorlessSource() async throws {
        let video = try await TestVideo.makeOffMain(width: 400, height: 200, seconds: 2)
        cleanup.append(video)
        let size = CGSize(width: 400, height: 200)

        let none = try await BakedCursor.render(video, size: size, events: events(hidden: false))
        XCTAssertNil(none, "nothing to draw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path), "a recording with its cursor stays the capture")

        let baked = try await BakedCursor.render(video, size: size, events: events(hidden: true))
        let result = try XCTUnwrap(baked)
        cleanup.append(result.url)
        cleanup.append(Sidecar.source.url(for: result.url))
        XCTAssertNotEqual(result.url, video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path), "the raw recording moved")
        let source = try XCTUnwrap(BakedCursor.source(for: result.url), "the raw recording is kept as the source")
        XCTAssertEqual(source.lastPathComponent, ".\(result.url.lastPathComponent).screenme-source.mp4", "hidden, next to the capture")
        XCTAssertEqual(source.deletingLastPathComponent(), result.url.deletingLastPathComponent())
        XCTAssertEqual(result.events.cursor?.hidden, false)
        XCTAssertNotNil(result.events.cursor, "the track stays for auto zoom")
        let rendered = try await TestVideo.size(of: result.url)
        XCTAssertEqual(rendered, size, "no background, same size")
        // Hotspot at (100, 120) pixels; 2 px per point. The arrow's black body runs down and right of it.
        let body = try await TestVideo.pixel(of: result.url, at: 1, x: 100 + 6, y: 120 + 14)
        XCTAssertLessThan(body.g, 100, "the arrow, not the green video")
        let far = try await TestVideo.pixel(of: result.url, at: 1, x: 380, y: 20)
        XCTAssertGreaterThan(far.g, 120, "the rest is the recording")
        let sourceBody = try await TestVideo.pixel(of: source, at: 1, x: 100 + 6, y: 120 + 14)
        XCTAssertGreaterThan(sourceBody.g, 120, "the source has no cursor")
    }
}
