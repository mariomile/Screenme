import AVFoundation
import XCTest
@testable import Screenme

final class VideoZoomTests: XCTestCase {
    private let point = CGPoint(x: 0.3, y: 0.4)

    // MARK: Segments from clicks

    func testAClickZoomsFromBeforeToAfterIt() {
        let segments = AutoZoom.segments(clicks: [(10, point)], switches: [], duration: 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 8.5, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 12, accuracy: 1e-9)
        XCTAssertEqual(segments[0].center, point)
        XCTAssertTrue(segments[0].isAuto)
        XCTAssertNil(segments[0].zoom)
    }

    func testClicksLessThanThreeSecondsApartShareOneZoom() {
        let segments = AutoZoom.segments(clicks: [(10, point), (12.5, CGPoint(x: 0.9, y: 0.9)), (15, point)], switches: [], duration: 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 8.5, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 17, accuracy: 1e-9)
        XCTAssertEqual(segments[0].center, point, "centered on the first click of the run")
    }

    func testClicksFurtherApartGetTheirOwnZoomsUnlessTheyOverlap() {
        let apart = AutoZoom.segments(clicks: [(10, point), (20, point)], switches: [], duration: 60)
        XCTAssertEqual(apart.map(\.start), [8.5, 18.5])
        // 3.2 s apart: two runs, but 10 + 2 is after 13.2 - 1.5, so the zooms join.
        let overlapping = AutoZoom.segments(clicks: [(10, point), (13.2, point)], switches: [], duration: 60)
        XCTAssertEqual(overlapping.count, 1)
        XCTAssertEqual(overlapping[0].end, 15.2, accuracy: 1e-9)
    }

    func testZoomsStayInsideTheVideoAndTinyOnesAreDropped() {
        let segments = AutoZoom.segments(clicks: [(0.5, point), (59.9, point)], switches: [], duration: 60)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[1].end, 60)
        XCTAssertTrue(AutoZoom.segments(clicks: [(0.1, point)], switches: [], duration: 0.3).isEmpty, "too short to zoom in and out")
    }

    func testAClickThatSwitchesWindowsDoesNotZoom() {
        let segments = AutoZoom.segments(clicks: [(10, point), (20, point), (30, point)], switches: [10.6, 19.8], duration: 60)
        XCTAssertEqual(segments.map(\.start), [28.5])
    }

    func testSegmentsFromRecordingEventsUseUnitCoordinatesAndSkipTheFirstApp() {
        let events = RecordingEvents(width: 200, height: 100, events: [
            .app("Safari", window: nil, time: 0),
            .click(at: CGPoint(x: 50, y: 25), time: 0.5),
            .shortcut("⌘S", time: 2),
        ])
        let segments = AutoZoom.segments(for: events, duration: 10)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].center, CGPoint(x: 0.25, y: 0.25))
    }

    // MARK: Camera

    func testTheZoomEasesInHoldsAndEasesOut() {
        let segment = ZoomSegment(start: 1, end: 5, center: CGPoint(x: 0.5, y: 0.5), zoom: 2, isAuto: false)
        let path = CameraPath(segments: [segment], strength: 1.8, cursor: nil, duration: 6)
        XCTAssertEqual(path.camera(at: 0.5).zoom, 1, accuracy: 1e-9)
        XCTAssertEqual(path.camera(at: 1).zoom, 1, accuracy: 1e-6)
        let rising = path.camera(at: 1.4).zoom
        XCTAssertGreaterThan(rising, 1.1)
        XCTAssertLessThan(rising, 2)
        XCTAssertEqual(path.camera(at: 3).zoom, 2, accuracy: 1e-6)
        XCTAssertLessThan(path.camera(at: 4.6).zoom, 2)
        XCTAssertEqual(path.camera(at: 5.5).zoom, 1, accuracy: 1e-9)
    }

    func testTheEaseStartsAndEndsGently() {
        XCTAssertEqual(CameraPath.ease(0), 0)
        XCTAssertEqual(CameraPath.ease(1), 1, accuracy: 1e-12)
        XCTAssertLessThan(CameraPath.ease(0.05), 0.05, "slow start")
        XCTAssertGreaterThan(CameraPath.ease(0.5), 0.5)
        var previous = 0.0
        for step in 1...100 {
            let value = CameraPath.ease(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testTheViewNeverLeavesTheVideo() {
        let corner = Camera(zoom: 2, center: CGPoint(x: 0.95, y: 0.02))
        XCTAssertEqual(corner.visibleRect, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(Camera(zoom: 1, center: CGPoint(x: 0.9, y: 0.9)).visibleRect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testTheCameraIgnoresTheCursorInsideTheDeadZone() {
        let focus = CGPoint(x: 0.5, y: 0.5)
        // A view half the video wide: the dead zone reaches 0.125 either side of the focus.
        XCTAssertEqual(CameraPath.follow(focus: focus, cursor: CGPoint(x: 0.6, y: 0.4), viewSize: 0.5), focus)
        let moved = CameraPath.follow(focus: focus, cursor: CGPoint(x: 0.8, y: 0.5), viewSize: 0.5)
        XCTAssertEqual(moved.x, 0.675, accuracy: 1e-9, "just far enough to bring the cursor back to the dead zone's edge")
        XCTAssertEqual(moved.y, 0.5)
    }

    func testAnAutomaticZoomFollowsTheCursorSmoothly() throws {
        var track = CursorTrack(hidden: true)
        // Still at the left until 2 s, then a jump to the right.
        track.add(time: 0, x: 20, y: 50)
        track.add(time: 2, x: 20, y: 50)
        track.add(time: 2.02, x: 180, y: 50)
        track.add(time: 6, x: 180, y: 50)
        let cursor = try XCTUnwrap(CursorPath(track: track, width: 200, height: 100))
        let segment = ZoomSegment(start: 0, end: 6, center: CGPoint(x: 0.1, y: 0.5), isAuto: true)
        let path = CameraPath(segments: [segment], strength: 2, cursor: cursor, duration: 6)
        XCTAssertEqual(path.camera(at: 1.5).center.x, 0.1, accuracy: 0.01, "the cursor sits still inside the dead zone")
        let soon = path.camera(at: 2.1).center.x
        let later = path.camera(at: 3.5).center.x
        XCTAssertLessThan(soon, later, "eases towards the cursor rather than jumping")
        XCTAssertEqual(later, 0.9 - 0.125, accuracy: 0.02)
    }

    // MARK: Export

    /// A 3x zoom on the white block of the test video fills the middle of the frame with white.
    @MainActor
    func testExportZoomsInOnTheSegment() async throws {
        let video = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 3)
        defer { try? FileManager.default.removeItem(at: video) }
        // The block of frame 32 covers x 0...40, y 60...82.
        let zoom = ZoomSegment(start: 0, end: 3, center: CGPoint(x: 20.0 / 320, y: 71.0 / 180), zoom: 3, isAuto: false)
        let edit = VideoEdit(zooms: [zoom])
        let source = VideoSource(size: CGSize(width: 320, height: 180), events: nil)
        let renderer = edit.renderer(for: source, renderSize: CGSize(width: 320, height: 180), duration: 3)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let output = try await VideoTranscoder.export(video, settings: VideoExportSettings(range: range, renderer: renderer, quality: .high, mute: true))
        defer { try? FileManager.default.removeItem(at: output) }

        let time = 32.5 / 30
        let inBlock = try await TestVideo.pixel(of: output, at: time, x: 60, y: 90)
        XCTAssertGreaterThan(inBlock.r, 200)
        XCTAssertGreaterThan(inBlock.g, 200)
        XCTAssertGreaterThan(inBlock.b, 200)
        let beside = try await TestVideo.pixel(of: output, at: time, x: 250, y: 90)
        XCTAssertLessThan(beside.r, 60)
        XCTAssertGreaterThan(beside.g, 120)
    }
}

final class CursorPathTests: XCTestCase {
    func testResamplingGivesEvenSamplesBetweenTheRecordedOnes() {
        let points = CursorPath.resample(times: [0, 0.1, 0.5], xs: [0, 1, 1], ys: [0, 0, 2], rate: 10)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(points[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(points[1].x, 1, accuracy: 1e-9)
        XCTAssertEqual(points[3].y, 1, accuracy: 1e-9, "halfway from 0.1 to 0.5")
        XCTAssertEqual(points[5].y, 2, accuracy: 1e-9)
    }

    func testAStillPointerStaysStillAcrossItsDedupedRun() throws {
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: 100, y: 100)
        for i in 1...60 { track.add(time: Double(i) / 60, x: 100, y: 100) }
        track.add(time: 1.1, x: 200, y: 100)
        let path = try XCTUnwrap(CursorPath(track: track, width: 400, height: 200))
        XCTAssertEqual(path.position(at: 0.5).x, 0.25, accuracy: 1e-4)
        XCTAssertEqual(path.position(at: 0.75).x, 0.25, accuracy: 0.002, "no drift while still")
    }

    func testSmoothingRemovesJitterWithoutLag() {
        // Alternating 1 px jitter around a steady line.
        let raw = (0..<120).map { CGPoint(x: Double($0) / 120 + ($0 % 2 == 0 ? 0.004 : -0.004), y: 0.5) }
        let smooth = CursorPath.smooth(raw, timeConstant: 0.05, rate: 60)
        let jitter: Double = (10..<110).map { Double(abs(smooth[$0].x - Double($0) / 120)) }.max() ?? 1
        XCTAssertLessThan(jitter, 0.002)
        XCTAssertEqual(smooth[60].x, 0.5, accuracy: 0.003, "centered: no lag behind the real position")
    }
}
