import XCTest
@testable import Screenme

final class CursorTrackTests: XCTestCase {
    func testAStillPointerKeepsOnlyTheFirstAndLastSampleOfTheRun() {
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: 10, y: 10)
        track.add(time: 0.1, x: 10, y: 10)
        track.add(time: 0.2, x: 10, y: 10)
        track.add(time: 0.3, x: 10, y: 10)
        track.add(time: 0.4, x: 20, y: 12)
        XCTAssertEqual(track.t, [0, 0.3, 0.4])
        XCTAssertEqual(track.x, [10, 10, 20])
        XCTAssertEqual(track.y, [10, 10, 12])
    }

    func testSamplesOutOfOrderAreDropped() {
        var track = CursorTrack(hidden: false)
        track.add(time: 0.5, x: 1, y: 1)
        track.add(time: 0.4, x: 2, y: 2)
        XCTAssertEqual(track.t, [0.5])
    }

    func testEventsWithoutACursorTrackStillDecode() throws {
        let json = #"{"width": 100, "height": 50, "events": []}"#
        let events = try JSONDecoder().decode(RecordingEvents.self, from: Data(json.utf8))
        XCTAssertNil(events.cursor)
        var withCursor = events
        withCursor.cursor = CursorTrack(hidden: true, t: [0], x: [1], y: [2], down: [0.5], up: [0.6])
        let decoded = try JSONDecoder().decode(RecordingEvents.self, from: withCursor.json())
        XCTAssertEqual(decoded, withCursor)
    }

    func testSmoothCursorFilmsWithoutTheCursorForVideosOnly() {
        var settings = RecordingSettings.saved
        settings.showCursor = true
        settings.smoothCursor = true
        settings.format = .video
        XCTAssertTrue(settings.rendersCursorLater)
        XCTAssertFalse(settings.filmsCursor)
        settings.format = .gif
        XCTAssertFalse(settings.rendersCursorLater)
        XCTAssertTrue(settings.filmsCursor)
    }
}
