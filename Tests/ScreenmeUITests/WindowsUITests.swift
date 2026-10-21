import XCTest

/// Screenme's own windows: History, Settings. Driven by links and keys only.
final class WindowsUITests: ScreenmeUITestCase {
    func testHistoryListsNewCaptures() {
        launch()
        // One capture at a time: a link that arrives during a capture is ignored, like a shortcut.
        run("capture-area", area: CGRect(x: 300, y: 300, width: 300, height: 200))
        waitForCaptures(1)
        run("capture-area", area: CGRect(x: 320, y: 320, width: 200, height: 150))
        waitForCaptures(2)
        run("open-history")
        let history = window("Capture History")
        XCTAssertTrue(history.images.count >= 2 || history.descendants(matching: .image).count >= 2, "the new captures should be listed")
    }

    func testSettingsSidebarChangesThePaneFromTheKeyboard() {
        launch()
        // Opening Screenme again while it runs shows Settings.
        let opened = expectation(description: "reopen")
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Screenme.app")
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in opened.fulfill() }
        wait(for: [opened], timeout: 10)
        let settings = window("Screenme Settings")
        let outline = settings.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        let rows = outline.outlineRows
        XCTAssertGreaterThanOrEqual(rows.count, 9)

        // Start from the top, then select each tab with the arrow keys and check the pane title follows.
        for _ in 0..<10 { settings.typeKey(.upArrow, modifierFlags: []) }
        for title in ["General", "Screenshots", "Quick Access", "Recording"] {
            if title != "General" { settings.typeKey(.downArrow, modifierFlags: []) }
            XCTAssertTrue(settings.staticTexts[title].waitForExistence(timeout: 3), "\(title) pane should show")
        }
    }
}
