import CoreGraphics
import XCTest
@testable import Screenme

/// Auto-crop: which window each keyframe is cut down to, from the events, the windows and the pointer.
final class AutoCropTests: XCTestCase {
    private func window(_ app: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WindowSnapshot.Window {
        WindowSnapshot.Window(app: app, title: nil, x: x, y: y, width: width, height: height)
    }

    /// Safari in front at the left, Notes behind it at the right, on a 1440 × 900 point screen.
    private lazy var desk = [window("Safari", 0, 0, 900, 700), window("Notes", 800, 100, 600, 700)]

    private func keyframes(_ times: [Double]) -> [Keyframe] {
        times.map { Keyframe(time: $0, moment: $0, reason: .click) }
    }

    private func events(_ list: [RecordingEvent], windows: [WindowSnapshot.Window]? = nil, cursor: [[Double]] = []) -> RecordingEvents {
        RecordingEvents(width: 1440, height: 900, events: list,
                        windows: [WindowSnapshot(time: 0, windows: windows ?? desk)], cursor: cursor)
    }

    func testCropsToTheWindowThatWasClickedWithPadding() {
        let crops = AutoCrop.crops(for: keyframes([1]), events: events([.click(at: CGPoint(x: 400, y: 300), right: false, time: 1)]))
        XCTAssertEqual(crops, [AutoCrop.Crop(rect: CGRect(x: 0, y: 0, width: 924, height: 724), apps: ["Safari"])])
    }

    func testTheFrontmostWindowUnderThePointWins() {
        // 850, 300 is in both windows: Safari is in front.
        let crops = AutoCrop.crops(for: keyframes([1]), events: events([.click(at: CGPoint(x: 850, y: 300), right: false, time: 1)]))
        XCTAssertEqual(crops.first??.apps, ["Safari"])
    }

    func testARestingPointerCountsAndATalkOnlyKeyframeKeepsTheCropBefore() {
        // The pointer rests in Notes from 0.5 s; keyframe 2 (at 10 s) has nothing in its stretch.
        let events = events([], cursor: [[0.5, 1000, 400]])
        let crops = AutoCrop.crops(for: keyframes([1, 10]), events: events)
        let notes = AutoCrop.Crop(rect: CGRect(x: 776, y: 76, width: 648, height: 748), apps: ["Notes"])
        XCTAssertEqual(crops, [notes, notes])
        XCTAssertEqual(AutoCrop.activity(from: 0, to: 1, in: events), [AutoCrop.Activity(point: CGPoint(x: 1000, y: 400), weight: 0.5)])
    }

    func testClicksOutweighAWanderingPointer() {
        let events = events([.click(at: CGPoint(x: 100, y: 100), right: false, time: 1)], cursor: [[0, 1000, 400], [1.5, 1001, 400]])
        XCTAssertEqual(AutoCrop.crops(for: keyframes([1]), events: events).first??.apps, ["Safari"])
    }

    func testAWindowFillingTheScreenStaysWhole() {
        let events = events([.click(at: CGPoint(x: 400, y: 300), right: false, time: 1)], windows: [window("Xcode", 0, 0, 1440, 900)])
        XCTAssertEqual(AutoCrop.crops(for: keyframes([1]), events: events), [nil])
    }

    func testASmallWindowIsWidenedInsideTheScreen() {
        let events = events([.click(at: CGPoint(x: 150, y: 150), right: false, time: 1)], windows: [window("Calculator", 100, 100, 200, 150)])
        XCTAssertEqual(AutoCrop.crops(for: keyframes([1]), events: events),
                       [AutoCrop.Crop(rect: CGRect(x: 0, y: 76, width: 480, height: 198), apps: ["Calculator"])])
    }

    func testAnArrowFromOneWindowToAnotherShowsBoth() {
        let windows = [window("Safari", 100, 100, 400, 300), window("Notes", 700, 100, 300, 300)]
        let arrow = RecordingEvent.drawing(.arrow, color: .red, box: CGRect(x: 300, y: 200, width: 500, height: 50),
                                           tip: CGPoint(x: 800, y: 250), time: 1)
        let crop = AutoCrop.crops(for: keyframes([1]), events: events([arrow], windows: windows)).first ?? nil
        XCTAssertEqual(crop?.apps, ["Safari", "Notes"])
        XCTAssertEqual(crop?.rect, CGRect(x: 76, y: 76, width: 948, height: 348))
    }

    func testInkOutsideTheWindowIsKeptInTheCrop() {
        let events = events([
            .click(at: CGPoint(x: 150, y: 150), right: false, time: 1),
            .drawing(.pen, color: .red, box: CGRect(x: 1300, y: 850, width: 40, height: 30), tip: nil, time: 1.2),
        ], windows: [window("Calculator", 100, 100, 200, 150)])
        let crop = AutoCrop.crops(for: keyframes([1]), events: events).first ?? nil
        XCTAssertNil(crop, "the window and the ink together are most of the screen")
    }

    func testNeighbouringCropsThatMostlyOverlapBecomeOne() {
        let a = AutoCrop.Crop(rect: CGRect(x: 0, y: 0, width: 600, height: 400), apps: ["Safari"])
        let b = AutoCrop.Crop(rect: CGRect(x: 40, y: 20, width: 600, height: 400), apps: ["Safari"])
        let far = AutoCrop.Crop(rect: CGRect(x: 900, y: 500, width: 500, height: 300), apps: ["Notes"])
        let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let union = AutoCrop.Crop(rect: CGRect(x: 0, y: 0, width: 640, height: 420), apps: ["Safari"])
        XCTAssertEqual(AutoCrop.merged([a, b, far, nil, a], area: area), [union, union, far, nil, a])
        XCTAssertEqual(AutoCrop.appNames([union, nil, far]), "Safari + Notes")
    }

    func testWithoutRecordedWindowsNothingIsCropped() {
        let events = RecordingEvents(width: 1440, height: 900, events: [.click(at: CGPoint(x: 400, y: 300), right: false, time: 1)])
        XCTAssertEqual(AutoCrop.crops(for: keyframes([1, 2]), events: events), [nil, nil])
    }

    func testCropsAPictureInItsPixels() {
        let image = CGImage.drawn(width: 2880, height: 1800, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in }!
        let cut = AIReporter.cropped(image, to: CGRect(x: 100, y: 50, width: 480, height: 300), area: CGSize(width: 1440, height: 900))
        XCTAssertEqual(cut?.width, 960)
        XCTAssertEqual(cut?.height, 600)
        XCTAssertEqual(AIReporter.fitted(image, maxSide: 1920).width, 1920)
        XCTAssertEqual(AIReporter.fitted(image, maxSide: 1920).height, 1200)
    }
}
