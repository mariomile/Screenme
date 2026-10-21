import Translation
import XCTest

/// The extra screenshot tools that can run without the pointer: Capture & Translate Text and Measure.
/// Pick Color needs a click on screen, and Redact and the Copy as Markdown menu need clicks in Screenme's
/// windows: their logic is covered by the unit tests.
@MainActor
final class ToolsUITests: ScreenmeUITestCase {
    func testCaptureAndTranslateCopiesTheTranslation() async throws {
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "it"), to: Locale.Language(identifier: "en"))
        try XCTSkipUnless(status == .installed, "Download Italian and English in System Settings > General > Language & Region > Translation Languages")
        prefs["translateTarget"] = "en"
        let window = showTestWindow("Buongiorno a tutti, oggi il tempo è molto bello e andiamo al mare.")
        launch()
        NSPasteboard.general.clearContents()
        run("translate-text", area: window)
        let text = waitForClipboardText(timeout: 20)
        if text.isEmpty { add(XCTAttachment(screenshot: XCUIScreen.main.screenshot())) }
        XCTAssertFalse(text.isEmpty, "a translation should be copied")
        XCTAssertTrue(text.lowercased().contains("sea") || text.lowercased().contains("weather"), "translation: \(text)")
        XCTAssertTrue(newCaptures().isEmpty, "translation keeps no file")
    }

    func testMeasureCopiesASizeAndEscapeCloses() {
        launch()
        NSPasteboard.general.clearContents()
        let before = app.windows.count + app.dialogs.count
        run("measure")
        XCTAssertTrue(eventually { self.app.windows.count + self.app.dialogs.count > before }, "the ruler should open")
        app.typeKey("c", modifierFlags: .command)
        let text = waitForClipboardText()
        XCTAssertFalse(text.isEmpty, "a size should be copied")
        XCTAssertNotNil(text.range(of: #"^\d+ × \d+$"#, options: .regularExpression), "copied: \(text)")
        XCTAssertTrue(newCaptures().isEmpty, "measuring keeps no file")
    }

    func testMeasureClosesOnEscapeWithoutCopying() {
        launch()
        NSPasteboard.general.clearContents()
        let before = app.windows.count + app.dialogs.count
        run("measure")
        XCTAssertTrue(eventually { self.app.windows.count + self.app.dialogs.count > before }, "the ruler should open")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
        XCTAssertNil(NSPasteboard.general.string(forType: .string))
        // Screenme is free for the next action.
        run("capture-fullscreen")
        waitForCaptures(1)
    }
}
