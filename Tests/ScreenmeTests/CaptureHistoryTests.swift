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

    /// Writes `sidecar` for `capture` the way its owner does.
    private func write(_ sidecar: Sidecar, for capture: URL) throws {
        switch sidecar {
        case .events, .source:
            try Data("x".utf8).write(to: sidecar.url(for: capture))
        case .edit:
            try EditSidecar.save(EditState(cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)), flattened: Data("x".utf8), to: capture)
        }
    }

    @MainActor func testTrashAndPruneTakeEverySidecarWithTheCapture() throws {
        Prefs[Pref.historyDays] = 30
        let now = Date()
        let cases: [(Sidecar, String)] = [(.events, "mp4"), (.edit, "png"), (.source, "mp4")]
        for (sidecar, ext) in cases {
            let trashed = try file("trashed.\(ext)", in: captures)
            let expired = try file("expired.\(ext)", in: captures)
            let kept = try file("kept.\(ext)", in: captures)
            for url in [trashed, expired, kept] { try write(sidecar, for: url) }
            let history = history()
            history.moveToTrash = { try FileManager.default.removeItem(at: $0) }
            let kind: CaptureItem.Kind = ext == "png" ? .image : .video
            let item = CaptureItem(url: trashed, kind: kind, date: now)
            history.add(item)
            history.add(CaptureItem(url: expired, kind: kind, date: now.addingTimeInterval(-31 * 86_400)))
            history.add(CaptureItem(url: kept, kind: kind, date: now))

            history.trash(item)
            history.prune(now: now)

            for url in [trashed, expired] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.url(for: url).path), "\(sidecar) of \(url.lastPathComponent)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            XCTAssertEqual(Sidecar.all(for: kept), [sidecar.url(for: kept)], "a capture still in History keeps its \(sidecar)")
            XCTAssertEqual(history.items.map(\.url), [kept])
            try FileManager.default.removeItem(at: captures)
            try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        }
    }

    /// Trash is never a hard delete: Put Back must find the capture and every sidecar it had.
    @MainActor func testTrashMovesTheCaptureAndItsSidecarsToTheTrash() throws {
        let trash = folder.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let capture = try file("both.mp4", in: captures)
        for sidecar in Sidecar.allCases { try write(sidecar, for: capture) }
        let history = history()
        history.moveToTrash = { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent)) }
        let item = CaptureItem(url: capture, kind: .video)
        history.add(item)
        var forgotten: [URL] = []
        let observer = Sidecar.onTrash { forgotten.append($0) }
        defer { NotificationCenter.default.removeObserver(observer) }

        history.trash(item)

        let inTrash = try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()
        XCTAssertEqual(inTrash, ([capture] + Sidecar.allCases.map { $0.url(for: capture) }).map(\.lastPathComponent).sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(".both.mp4.screenme-edit/edit.json").path))
        XCTAssertEqual(forgotten, [capture], "one notification tells memory to forget the capture")
    }
}
