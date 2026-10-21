import CoreMedia
import XCTest
@testable import Screenme

final class PauseTimelineTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private let none = CMTime.zero

    func testWithoutPausesFileTimeIsCaptureTimeMinusStart() {
        let timeline = PauseTimeline(start: t(10))
        XCTAssertEqual(timeline.outputTime(for: t(12), duration: none), t(12))
        XCTAssertFalse(timeline.isPaused)
        XCTAssertEqual(timeline.end(at: t(15)), t(15))
    }

    func testSamplesBeforeStartAreDropped() {
        let timeline = PauseTimeline(start: t(10))
        XCTAssertNil(timeline.outputTime(for: t(9.9), duration: none))
    }

    func testPausedTimeIsCutOut() {
        var timeline = PauseTimeline(start: t(0))
        timeline.pause(at: t(5))
        XCTAssertTrue(timeline.isPaused)
        timeline.resume(at: t(8))
        XCTAssertFalse(timeline.isPaused)
        XCTAssertEqual(timeline.outputTime(for: t(8), duration: none), t(5), "resume continues exactly where the pause began")
        XCTAssertEqual(timeline.outputTime(for: t(10), duration: none), t(7))
        XCTAssertEqual(timeline.end(at: t(12)), t(9))
    }

    func testSamplesDuringAPauseAreDropped() {
        var timeline = PauseTimeline(start: t(0))
        timeline.pause(at: t(5))
        XCTAssertNil(timeline.outputTime(for: t(5), duration: none))
        XCTAssertNil(timeline.outputTime(for: t(6), duration: none))
        timeline.resume(at: t(8))
        XCTAssertNil(timeline.outputTime(for: t(7), duration: none), "captured while paused")
    }

    func testSamplesStraddlingAPauseOrResumeAreDropped() {
        var timeline = PauseTimeline(start: t(0))
        XCTAssertNotNil(timeline.outputTime(for: t(4), duration: t(1)))
        timeline.pause(at: t(5))
        XCTAssertNil(timeline.outputTime(for: t(4.5), duration: t(1)), "runs past the pause")
        XCTAssertNotNil(timeline.outputTime(for: t(4), duration: t(1)), "ends exactly at the pause")
        timeline.resume(at: t(8))
        XCTAssertNil(timeline.outputTime(for: t(7.5), duration: t(1)), "starts before the resume")
    }

    func testEndWhilePausedIsWherePauseBegan() {
        var timeline = PauseTimeline(start: t(0))
        timeline.pause(at: t(5))
        XCTAssertEqual(timeline.end(at: t(20)), t(5))
    }

    func testMultiplePausesAccumulate() {
        var timeline = PauseTimeline(start: t(0))
        timeline.pause(at: t(2)); timeline.resume(at: t(3))   // cuts 1
        timeline.pause(at: t(6)); timeline.resume(at: t(10))  // cuts 4
        XCTAssertEqual(timeline.outputTime(for: t(12), duration: none), t(7))
        XCTAssertEqual(timeline.end(at: t(12)), t(7))
    }

    func testRepeatedPauseAndStrayResumeAreIgnored() {
        var timeline = PauseTimeline(start: t(0))
        timeline.resume(at: t(3)) // not paused: no-op
        XCTAssertEqual(timeline.outputTime(for: t(4), duration: none), t(4))
        timeline.pause(at: t(5))
        timeline.pause(at: t(6)) // second pause keeps the first moment
        timeline.resume(at: t(7))
        XCTAssertEqual(timeline.outputTime(for: t(7), duration: none), t(5))
    }

    func testPauseBeforeStretchStartIsClamped() {
        var timeline = PauseTimeline(start: t(10))
        timeline.pause(at: t(3))
        timeline.resume(at: t(4))
        XCTAssertEqual(timeline.outputTime(for: t(10), duration: none), t(10), "nothing is cut when pause and resume precede the start")
    }
}
