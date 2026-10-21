import XCTest
@testable import Screenme

/// "Keep captures for" trashes expired captures in Screenme's own folder, never files elsewhere.
final class CaptureHistoryTests: PrefsSandboxTestCase {
    private var folder: URL!
    private var captures: URL!
    private var elsewhere: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        captures = folder.appendingPathComponent("Captures", isDirectory: true)
        elsewhere = folder.appendingPathComponent("Desktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @MainActor private func history() -> CaptureHistory {
        CaptureHistory(indexURL: folder.appendingPathComponent("history.json"), capturesDirectory: captures)
    }

    @MainActor func testPruneTrashesExpiredOwnCapturesAndKeepsRecentOnes() throws {
        Prefs[Pref.historyDays] = 30
        let now = Date()
        let old = try file("old.mov", in: captures)
        let oldEvents = try file(".old.mov.events.json", in: captures)
        let recent = try file("recent.png", in: captures)
        let history = history()
        history.add(CaptureItem(url: old, kind: .video, date: now.addingTimeInterval(-31 * 86_400)))
        history.add(CaptureItem(url: recent, kind: .image, date: now.addingTimeInterval(-29 * 86_400)))

        history.prune(now: now)

        XCTAssertEqual(history.items.map(\.url), [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEvents.path), "the events sidecar goes with its recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    @MainActor func testPruneNeverTouchesFilesOutsideTheCapturesFolder() throws {
        Prefs[Pref.historyDays] = 30
        let now = Date()
        let saved = try file("saved.png", in: elsewhere)
        let history = history()
        history.add(CaptureItem(url: saved, kind: .image, date: now.addingTimeInterval(-60 * 86_400)))

        history.prune(now: now)

        XCTAssertTrue(history.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    @MainActor func testKeepForeverKeepsOldCapturesAndDropsEntriesWhoseFileIsGone() throws {
        Prefs[Pref.historyDays] = 0
        let now = Date()
        let old = try file("old.png", in: captures)
        let gone = captures.appendingPathComponent("gone.png")
        let history = history()
        history.add(CaptureItem(url: old, kind: .image, date: now.addingTimeInterval(-400 * 86_400)))
        history.add(CaptureItem(url: gone, kind: .image, date: now))

        history.prune(now: now)

        XCTAssertEqual(history.items.map(\.url), [old])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }
}
