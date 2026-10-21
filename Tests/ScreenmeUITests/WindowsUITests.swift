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
        run("settings?tab=general")
        let settings = window("Screenme Settings")
        let outline = settings.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        let rows = outline.outlineRows
        XCTAssertGreaterThanOrEqual(rows.count, 9)

        // From General, select each tab with the arrow keys and check the pane title follows.
        for title in ["General", "Screenshots", "Quick Access", "Recording"] {
            if title != "General" { settings.typeKey(.downArrow, modifierFlags: []) }
            XCTAssertTrue(settings.staticTexts[title].waitForExistence(timeout: 3), "\(title) pane should show")
        }
    }
}

/// The annotation editor opened after a capture.
final class EditorUITests: ScreenmeUITestCase {
    func testEditorOpensOnThePointersScreenAndCopyCanClose() throws {
        prefs["afterShotOpenEditor"] = "<true/>"
        prefs["editor.closeAfterCopy"] = "<true/>"
        launch()
        run("capture-area", area: CGRect(x: 300, y: 300, width: 400, height: 260))
        let capture = try XCTUnwrap(waitForCaptures(1).first)
        let editor = window(capture.lastPathComponent)

        let pointer = NSEvent.mouseLocation
        let screen = try XCTUnwrap(NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) })
        // XCUI frames are top-left points from the top of the first screen.
        let top = NSScreen.screens[0].frame.maxY
        let center = CGPoint(x: editor.frame.midX, y: top - editor.frame.midY)
        XCTAssertTrue(screen.frame.contains(center), "the editor should open on the screen the pointer is on")

        NSPasteboard.general.clearContents()
        editor.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(eventually { NSPasteboard.general.data(forType: .png) != nil }, "the image should be copied")
        XCTAssertTrue(eventually { !editor.exists }, "the editor should close after copying")
    }
}
