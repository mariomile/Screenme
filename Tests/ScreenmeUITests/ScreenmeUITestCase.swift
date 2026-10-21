import AppKit
import XCTest

/// Base for the end-to-end tests. Launches the Debug build that `scripts/ui-test.sh` signed like the installed app,
/// with test preferences passed as launch arguments: they override the user's settings for this run only and
/// are never written to disk. Actions start through `screenme://` links, the same way Shortcuts or Raycast would,
/// and areas and windows are named in the link, so the tests never move the pointer: they run while you work.
/// Keys go to Screenme's own windows only. Every capture a test creates is deleted afterwards.
class ScreenmeUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var existingCaptures: Set<String> = []
    private var cleanup: [URL] = []

    static let captures = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenme/Captures", isDirectory: true)
    /// The save folder for this run, so Save never writes into the user's real folder.
    static let saveFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeUITestsSaved", isDirectory: true)

    /// The app next to the test runner in the build products.
    private static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Screenme.app")
    }

    /// Preferences for a predictable run. Tests add or override entries before `launch()`.
    var prefs: [String: String] = [
        "onboardingDone": "<true/>",
        "playSounds": "<false/>",
        "afterShotQuickAccess": "<true/>",
        "afterShotCopy": "<true/>",
        "afterShotSave": "<false/>",
        "afterShotOpenEditor": "<false/>",
        "afterShotPin": "<false/>",
        "afterRecordingQuickAccess": "<true/>",
        "afterRecordingCopy": "<false/>",
        "afterRecordingSave": "<false/>",
        "afterRecordingOpenEditor": "<false/>",
        "quickAccessAutoClose": "<integer>0</integer>",
        "quickAccessCloseAfterDrag": "<true/>",
        "freezeScreen": "<false/>",
        "hideNotch": "<false/>",
        "hideDesktopIconsInShots": "<false/>",
        "watermarkEnabled": "<false/>",
        "imageFormat": "png",
        "recordingFormat": "video",
        "recordingCountdown": "<integer>0</integer>",
        "recordingWebcam": "<false/>",
        "recordingMicrophone": "<false/>",
        "recordingSystemAudio": "<false/>",
        "recordingHideDesktopIcons": "<false/>",
        "selfTimerSeconds": "<integer>3</integer>",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: Self.saveFolder, withIntermediateDirectories: true)
        prefs["saveDirectory"] = Self.saveFolder.path
        existingCaptures = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.captures.path)) ?? [])
    }

    func launch() {
        app = XCUIApplication()
        app.launchArguments = prefs.flatMap { ["-\($0.key)", $0.value] }
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 10), "the menu bar icon should appear")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        for url in newCaptures() + cleanup { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: Self.saveFolder)
    }

    /// Files to delete after the test, e.g. documents a test opened in another app.
    func deleteAfterwards(_ url: URL) { cleanup.append(url) }

    // MARK: Actions

    /// Runs `screenme://<name>` in the app under test.
    func run(_ name: String) {
        let opened = expectation(description: "open screenme://\(name)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([URL(string: "screenme://\(name)")!], withApplicationAt: Self.appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
    }

    // MARK: Captures

    /// Captures created since the test started, oldest first.
    func newCaptures() -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.captures.path)) ?? [])
            .filter { !existingCaptures.contains($0) && !$0.hasPrefix(".") }
        return names.map { Self.captures.appendingPathComponent($0) }
            .sorted { modified($0) < modified($1) }
    }

    /// Waits until there are `count` new captures (of one file type when `ofType` is set) and returns them.
    /// A recording's MP4 exists from its first frame, so recordings wait for their type and a settled size.
    @discardableResult
    func waitForCaptures(_ count: Int = 1, ofType type: String? = nil, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) -> [URL] {
        func matching() -> [URL] { newCaptures().filter { type == nil || $0.pathExtension == type } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = matching()
            if found.count >= count { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("expected \(count) new capture(s)\(type.map { " of type \($0)" } ?? ""), found \(newCaptures().map(\.lastPathComponent))",
                file: file, line: line)
        return matching()
    }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func pixelSize(_ url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        return CGSize(width: width, height: height)
    }

    // MARK: Screen

    /// The main screen in top-left points.
    var screenFrame: CGRect { NSScreen.screens[0].frame }
    var backingScale: CGFloat { NSScreen.screens[0].backingScaleFactor }

    /// `screenme://<name>?x=…&y=…&width=…&height=…` for a rect in top-left screen points.
    func run(_ name: String, area: CGRect) {
        run("\(name)?x=\(Int(area.minX))&y=\(Int(area.minY))&width=\(Int(area.width))&height=\(Int(area.height))")
    }

    /// Within two pixels: rounding of points to pixels.
    func assertSize(_ size: CGSize, _ expected: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width, expected.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(size.height, expected.height, accuracy: 2, file: file, line: line)
    }

    /// Waits for a Screenme window whose title matches.
    func window(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let match = app.windows[title]
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "window \(title) should open")
        return match
    }

    /// Polls until `condition` holds.
    @discardableResult
    func eventually(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // MARK: Test window

    /// Shows `text` in a window of the test runner, in front at a known place, and returns its frame in
    /// top-left screen points. Tests capture this window, never the user's apps. A normal window level, because
    /// `capture-window` picks normal windows.
    func showTestWindow(_ text: String, size: CGSize = CGSize(width: 760, height: 220)) -> CGRect {
        let screen = NSScreen.screens[0].frame
        let cocoa = CGRect(x: 120, y: screen.height - 140 - size.height, width: size.width, height: size.height)
        let window = NSWindow(contentRect: cocoa, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .black
        label.frame = CGRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return CGRect(x: cocoa.minX, y: screen.height - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// The test runner's bundle ID, for `capture-window?app=`.
    var runnerBundleID: String { Bundle.main.bundleIdentifier ?? "" }
}
