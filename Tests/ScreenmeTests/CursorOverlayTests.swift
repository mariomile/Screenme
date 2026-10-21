import AVFoundation
import XCTest
@testable import Screenme

final class CursorOverlayTests: XCTestCase {
    private func path(still at: CGPoint = CGPoint(x: 100, y: 50), until end: Double = 4) -> (CursorTrack, CursorPath) {
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: at.x, y: at.y)
        track.add(time: end, x: at.x, y: at.y)
        return (track, CursorPath(track: track, width: 200, height: 100)!)
    }

    func testEachPressPairsWithTheNextRelease() {
        let pairs = CursorOverlay.pair(downs: [3, 1], ups: [1.2, 3.5])
        XCTAssertEqual(pairs.map(\.down), [1, 3])
        XCTAssertEqual(pairs.map(\.up), [1.2, 3.5])
        XCTAssertEqual(CursorOverlay.pair(downs: [2], ups: []).first?.up ?? 0, 2.1, accuracy: 1e-9, "a lost release is a tap")
    }

    @MainActor
    func testTheHighlightSpringsInWhilePressedThenGrowsAndFades() {
        var (track, cursorPath) = path()
        track.down = [1]
        track.up = [1.5]
        let overlay = CursorOverlay(path: cursorPath, track: track, style: CursorStyle(), pixelsPerPoint: 1)
        XCTAssertNil(overlay.highlight(at: 0.9))
        let start = overlay.highlight(at: 1)
        XCTAssertEqual(start?.scale ?? 0, 0.35, accuracy: 1e-9)
        XCTAssertEqual(overlay.highlight(at: 1.4)?.scale ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(overlay.highlight(at: 1.4)?.alpha, 1)
        let fading = overlay.highlight(at: 1.66)
        XCTAssertGreaterThan(fading?.scale ?? 0, 1)
        XCTAssertLessThan(fading?.alpha ?? 1, 1)
        XCTAssertNil(overlay.highlight(at: 1.9))
    }

    func testHideWhenIdleFadesAfterTwoSecondsAndComesBackOnMove() throws {
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: 10, y: 10)
        track.add(time: 5, x: 10, y: 10)
        track.add(time: 5.2, x: 150, y: 80)
        track.add(time: 6, x: 150, y: 80)
        let cursorPath = try XCTUnwrap(CursorPath(track: track, width: 200, height: 100))
        let opacity = CursorOverlay.idleOpacity(path: cursorPath, presses: [])
        XCTAssertEqual(opacity[60], 1, "1 s still")
        XCTAssertEqual(opacity[Int(2.15 * 60)], 0.5, accuracy: 0.05, "halfway through the fade")
        XCTAssertEqual(opacity[Int(4 * 60)], 0, "gone")
        XCTAssertEqual(opacity[Int(5.4 * 60)], 1, "back once it moves")
    }

    /// A Smooth cursor recording exported with the cursor on: the arrow's dark body sits just below and right of the
    /// recorded position, and the click highlight tints the video around it.
    @MainActor
    func testExportDrawsTheCursorAndItsClickHighlight() async throws {
        let video = try await TestVideo.make(width: 400, height: 200, seconds: 2)
        defer { try? FileManager.default.removeItem(at: video) }
        var events = RecordingEvents(width: 200, height: 100, events: [])
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: 50, y: 60)
        track.add(time: 2, x: 50, y: 60)
        track.down = [0.5]
        track.up = [1.9]
        events.cursor = track
        let source = VideoSource(size: CGSize(width: 400, height: 200), events: events)
        var edit = VideoEdit()
        edit.cursor = CursorStyle(show: true, size: 1, clickHighlight: true, hideWhenIdle: false)
        XCTAssertTrue(edit.drawsCursor(for: source))
        XCTAssertFalse(edit.isPlain(for: source))
        let renderer = edit.renderer(for: source, renderSize: CGSize(width: 400, height: 200), duration: 2)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let output = try await VideoTranscoder.export(video, settings: VideoExportSettings(range: range, renderer: renderer, quality: .high, mute: true))
        defer { try? FileManager.default.removeItem(at: output) }

        // Hotspot at (100, 120) pixels; 2 px per point. The arrow's black body runs down and right of it.
        let body = try await TestVideo.pixel(of: output, at: 1, x: 100 + 6, y: 120 + 14)
        XCTAssertLessThan(body.g, 100, "the arrow, not the green video")
        let ring = try await TestVideo.pixel(of: output, at: 1, x: 100 - 40, y: 120)
        XCTAssertGreaterThan(ring.r, 60, "yellow highlight over green")
        let far = try await TestVideo.pixel(of: output, at: 1, x: 380, y: 20)
        XCTAssertLessThan(far.r, 40)
    }

    func testRecordingsWithTheCursorInThePictureDrawNone() {
        var track = CursorTrack(hidden: false)
        track.add(time: 0, x: 1, y: 1)
        var events = RecordingEvents(width: 200, height: 100, events: [])
        events.cursor = track
        let source = VideoSource(size: CGSize(width: 400, height: 200), events: events)
        XCTAssertFalse(VideoEdit().drawsCursor(for: source))
        XCTAssertTrue(VideoEdit().isPlain(for: source))
    }
}
