import Vision
import XCTest

/// Screenshots end to end: each action produces a file of the right size and lands in Quick Access and the clipboard.
final class CaptureUITests: ScreenmeUITestCase {
    func testFullscreenCaptureWritesTheWholeScreenCopiesItAndShowsQuickAccess() {
        launch()
        NSPasteboard.general.clearContents()
        run("capture-fullscreen")
        let file = waitForCaptures(1)[0]
        XCTAssertEqual(pixelSize(file), CGSize(width: screenFrame.width * backingScale, height: screenFrame.height * backingScale))
        XCTAssertTrue(eventually { NSPasteboard.general.availableType(from: [.png, .tiff]) != nil }, "the capture should be on the clipboard")
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5), "a Quick Access card should appear")
    }

    func testAreaCaptureMatchesTheRequestedRectangleAndPreviousAreaRepeatsIt() {
        launch()
        run("capture-area", area: CGRect(x: 300, y: 300, width: 400, height: 250))
        let file = waitForCaptures(1)[0]
        assertSize(pixelSize(file), CGSize(width: 400 * backingScale, height: 250 * backingScale))

        run("capture-previous-area")
        let again = waitForCaptures(2)[1]
        XCTAssertEqual(pixelSize(again), pixelSize(file))
    }

    func testEscapeCancelsTheSelection() {
        launch()
        run("capture-area")
        sleep(1)
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
        XCTAssertTrue(newCaptures().isEmpty)
        run("capture-fullscreen")
        waitForCaptures(1)
    }

    func testWindowCaptureGrabsThatAppsWindow() {
        let window = showTestWindow("Window capture test")
        launch()
        run("capture-window?app=\(runnerBundleID)")
        let size = pixelSize(waitForCaptures(1)[0])
        // The window, plus its shadow when that preference is on.
        XCTAssertGreaterThanOrEqual(size.width, window.width * backingScale - 2)
        XCTAssertLessThan(size.width, (window.width + 200) * backingScale)
    }

    func testTextCaptureCopiesTheRecognizedText() {
        let window = showTestWindow("SCREENME OCR CHECK 4821\nThe quick brown fox jumps over the lazy dog.")
        launch()
        NSPasteboard.general.clearContents()
        run("capture-text", area: window)
        var text = ""
        XCTAssertTrue(eventually { text = NSPasteboard.general.string(forType: .string) ?? ""; return !text.isEmpty })
        XCTAssertTrue(text.contains("SCREENME OCR CHECK 4821"), "OCR read: \(text)")
        XCTAssertTrue(text.lowercased().contains("quick brown fox"), "OCR read: \(text)")
        XCTAssertTrue(newCaptures().isEmpty, "text capture keeps no file")
    }

    func testSelfTimerCapturesAfterTheCountdown() {
        launch()
        run("self-timer", area: CGRect(x: 200, y: 200, width: 300, height: 200))
        sleep(1)
        XCTAssertTrue(newCaptures().isEmpty, "nothing before the countdown ends")
        let file = waitForCaptures(1, timeout: 8)[0]
        assertSize(pixelSize(file), CGSize(width: 300 * backingScale, height: 200 * backingScale))
    }

    func testAllInOneBarStartsTheChosenCaptureFromTheKeyboard() {
        launch()
        run("all-in-one")
        let shown = app.buttons["Fullscreen"].waitForExistence(timeout: 5)
        if !shown { add(XCTAttachment(screenshot: XCUIScreen.main.screenshot())) }
        XCTAssertTrue(shown, "the All-in-One bar should open")
        // Area, Window, Fullscreen: two to the right, then Return.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForCaptures(1)
        XCTAssertFalse(app.buttons["Fullscreen"].exists, "the bar closes")
    }

    func testCaptureLinkWhileTheAllInOneBarIsOpenRunsThatCapture() {
        launch()
        run("all-in-one")
        XCTAssertTrue(app.buttons["Fullscreen"].waitForExistence(timeout: 5))
        run("capture-fullscreen")
        waitForCaptures(1)
        XCTAssertFalse(app.buttons["Fullscreen"].exists, "the bar closes")
    }

    func testPinLastCaptureOpensAPin() {
        launch()
        run("capture-area", area: CGRect(x: 300, y: 300, width: 300, height: 200))
        waitForCaptures(1)
        let before = app.windows.count + app.dialogs.count
        run("pin-last-capture")
        XCTAssertTrue(eventually { self.app.windows.count + self.app.dialogs.count > before }, "a pin window should open")
    }

    func testWatermarkIsDrawnIntoTheScreenshot() {
        prefs["watermarkEnabled"] = "<true/>"
        prefs["watermarkText"] = "UITEST MARK"
        launch()
        run("capture-area", area: CGRect(x: 200, y: 200, width: 600, height: 300))
        let file = waitForCaptures(1)[0]
        let image = NSImage(contentsOf: file)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let text = recognizeText(image)
        XCTAssertTrue(text.contains("UITEST MARK"), "watermark text not found, OCR read: \(text)")
    }

    private func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
