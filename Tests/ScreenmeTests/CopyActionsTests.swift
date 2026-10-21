import XCTest
@testable import Screenme

/// Copy as Markdown and Copy Path: the link text, and finding the copy Save already made.
final class CopyActionsTests: PrefsSandboxTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Saved"), withIntermediateDirectories: true)
        Prefs[Pref.saveDirectory] = folder.appendingPathComponent("Saved").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testMarkdownUsesTheNameWithoutExtensionAndAnEncodedPath() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/Screenme 2026-10-21 at 10.00.00.png")
        XCTAssertEqual(CaptureAction.markdownImage(for: url),
                       "![Screenme 2026-10-21 at 10.00.00](/Users/me/Desktop/Screenme%202026-10-21%20at%2010.00.00.png)")
    }

    func testMarkdownEncodesParenthesesSoTheLinkDoesNotEndEarly() {
        let url = URL(fileURLWithPath: "/tmp/shot (1).gif")
        XCTAssertEqual(CaptureAction.markdownImage(for: url), "![shot (1)](/tmp/shot%20%281%29.gif)")
    }

    func testSavedCopyIsFoundUnderItsOwnOrANumberedName() throws {
        let capture = folder.appendingPathComponent("Shot.png")
        try Data("new".utf8).write(to: capture)
        XCTAssertNil(Storage.savedCopy(of: capture))

        // A different file already holds the name: Save wrote "Shot 2.png".
        try Data("old".utf8).write(to: Storage.saveDirectory.appendingPathComponent("Shot.png"))
        let saved = try Storage.save(capture)
        XCTAssertEqual(saved.lastPathComponent, "Shot 2.png")
        XCTAssertEqual(Storage.savedCopy(of: capture), saved)
    }

    func testAnEditedCaptureNoLongerMatchesItsSavedCopy() throws {
        let capture = folder.appendingPathComponent("Shot.png")
        try Data("before".utf8).write(to: capture)
        try Storage.save(capture)
        try Data("after".utf8).write(to: capture)
        XCTAssertNil(Storage.savedCopy(of: capture))
    }
}
