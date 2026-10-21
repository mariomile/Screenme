import AVFoundation
import XCTest

/// Recordings end to end: a link starts recording an area at once, the same link stops it, the file plays.
@MainActor
final class RecordingUITests: ScreenmeUITestCase {
    func testRecordingAnAreaWritesAVideoOfThatSizeAndLength() async throws {
        launch()
        run("record-screen", area: CGRect(x: 200, y: 200, width: 400, height: 300))
        sleep(3)
        run("record-screen")
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10), "a Quick Access card should appear when the recording is done")
        let file = waitForCaptures(1, ofType: "mp4")[0]
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 2, "about three seconds were recorded")
        XCTAssertLessThan(duration, 6)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        assertSize(size, CGSize(width: 400 * backingScale, height: 300 * backingScale))
    }

    func testGIFRecordingWritesAnAnimatedGIFAndNoVideo() {
        prefs["recordingFormat"] = "gif"
        launch()
        run("record-screen", area: CGRect(x: 200, y: 200, width: 320, height: 200))
        sleep(2)
        run("record-screen")
        let file = waitForCaptures(1, ofType: "gif", timeout: 30)[0]
        let source = try! XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 5, "an animation, not a still")
        XCTAssertTrue(eventually { self.newCaptures().allSatisfy { $0.pathExtension == "gif" } }, "the intermediate video is removed")
    }

    func testScreenshotLinksDoNothingWhileRecording() {
        launch()
        run("record-screen", area: CGRect(x: 200, y: 200, width: 300, height: 200))
        sleep(1)
        run("capture-fullscreen")
        sleep(1)
        XCTAssertTrue(newCaptures().allSatisfy { $0.pathExtension == "mp4" }, "no screenshot during a recording")
        run("record-screen")
        waitForCaptures(1, ofType: "mp4", timeout: 15)
    }
}
