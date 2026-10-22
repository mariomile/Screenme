import XCTest
@testable import Screenme

/// What happens after a capture, from the settings, and a Quick Access card waiting for its file.
@MainActor
final class AfterCaptureTests: PrefsSandboxTestCase {
    private struct WriteFailed: Error {}

    func testScreenshotPlanFollowsEverySetting() {
        for copy in [false, true] {
            for save in [false, true] {
                for pin in [false, true] {
                    for editor in [false, true] {
                        for quickAccess in [false, true] {
                            Prefs[Pref.afterShotCopy] = copy
                            Prefs[Pref.afterShotSave] = save
                            Prefs[Pref.afterShotPin] = pin
                            Prefs[Pref.afterShotOpenEditor] = editor
                            Prefs[Pref.afterShotQuickAccess] = quickAccess
                            let expected = AfterCapture(copy: copy, save: save, pin: pin,
                                                        presentation: editor ? .editor : quickAccess ? .quickAccess : .none)
                            XCTAssertEqual(AfterCapture.plan(for: .image), expected,
                                           "copy \(copy) save \(save) pin \(pin) editor \(editor) quick access \(quickAccess)")
                        }
                    }
                }
            }
        }
    }

    func testRecordingPlanFollowsEverySettingAndGIFsHaveNoEditor() {
        Prefs[Pref.afterShotPin] = true // the screenshot setting never pins a recording
        for copy in [false, true] {
            for save in [false, true] {
                for editor in [false, true] {
                    for quickAccess in [false, true] {
                        Prefs[Pref.afterRecordingCopy] = copy
                        Prefs[Pref.afterRecordingSave] = save
                        Prefs[Pref.afterRecordingOpenEditor] = editor
                        Prefs[Pref.afterRecordingQuickAccess] = quickAccess
                        let shown: AfterCapture.Presentation = quickAccess ? .quickAccess : .none
                        let label = "copy \(copy) save \(save) editor \(editor) quick access \(quickAccess)"
                        XCTAssertEqual(AfterCapture.plan(for: .video),
                                       AfterCapture(copy: copy, save: save, presentation: editor ? .editor : shown), label)
                        XCTAssertEqual(AfterCapture.plan(for: .gif), AfterCapture(copy: copy, save: save, presentation: shown), label)
                    }
                }
            }
        }
    }

    func testDefaultsCopyAndShowQuickAccess() {
        XCTAssertEqual(AfterCapture.plan(for: .image), AfterCapture(copy: true, presentation: .quickAccess))
        XCTAssertEqual(AfterCapture.plan(for: .video), AfterCapture(presentation: .quickAccess))
    }

    func testAnActionQueuedOnACardRunsOnceTheFileIsWritten() async {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        let model = CardModel(item: CaptureItem(url: url, kind: .image), preview: nil, file: Task { url })
        XCTAssertFalse(model.canDrag)
        var ran = false
        let error = await model.whenWritten { ran = true }
        XCTAssertNil(error)
        XCTAssertTrue(ran)
        XCTAssertTrue(model.canDrag)
    }

    func testAFailedWriteNeverRunsTheQueuedAction() async {
        let item = CaptureItem(url: URL(fileURLWithPath: "/tmp/shot.png"), kind: .image)
        let file = Task<URL, Error> {
            try await Task.sleep(for: .milliseconds(50))
            throw WriteFailed()
        }
        let model = CardModel(item: item, preview: nil, file: file)
        var ran = false
        let error = await model.whenWritten { ran = true }
        XCTAssertTrue(error is WriteFailed)
        XCTAssertFalse(ran)
        XCTAssertFalse(model.canDrag, "a drag never starts on a file that does not exist")
    }
}
