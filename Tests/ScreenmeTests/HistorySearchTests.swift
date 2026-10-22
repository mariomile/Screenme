import XCTest
@testable import Screenme

/// History search matches the date, kind and file name, and the text found in the image.
final class HistorySearchTests: XCTestCase {
    private let details = "Today Tuesday October 20 screenshot image Screenme 2026-10-20 at 10.14.png"

    func testNoQueryMatchesEverything() {
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("  "), details: details, imageText: nil))
    }

    func testMatchesDetailsWithoutImageText() {
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("tuesday screenshot"), details: details, imageText: nil))
        XCTAssertFalse(HistorySearch.matches(HistorySearch.tokens("invoice"), details: details, imageText: nil))
    }

    func testMatchesTextInTheImage() {
        let text = "Invoice 4821\nTotal due: 1.250,00 EUR"
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("invoice"), details: details, imageText: text))
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("1.250,00"), details: details, imageText: text))
        XCTAssertFalse(HistorySearch.matches(HistorySearch.tokens("receipt"), details: details, imageText: text))
    }

    func testEveryWordMustMatchInDetailsOrText() {
        let text = "Quarterly report"
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("tuesday quarterly"), details: details, imageText: text))
        XCTAssertFalse(HistorySearch.matches(HistorySearch.tokens("tuesday annual"), details: details, imageText: text))
    }

    func testCaseAndDiacriticsDoNotMatter() {
        let text = "Résumé de la réunion à Zürich"
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("RESUME"), details: details, imageText: text))
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("reunion zurich"), details: details, imageText: text))
        XCTAssertTrue(HistorySearch.matches(HistorySearch.tokens("réunion"), details: details, imageText: "REUNION"))
    }

    func testExcerptIsTheMatchingLine() {
        let text = "Header\nPlease pay the invoice by Friday\nFooter"
        XCTAssertEqual(HistorySearch.excerpt(of: text, matching: HistorySearch.tokens("INVOICE")), "Please pay the invoice by Friday")
        XCTAssertNil(HistorySearch.excerpt(of: text, matching: HistorySearch.tokens("receipt")))
        XCTAssertNil(HistorySearch.excerpt(of: nil, matching: HistorySearch.tokens("invoice")))
        XCTAssertNil(HistorySearch.excerpt(of: text, matching: []))
    }

    func testExcerptIsCut() {
        let line = String(repeating: "word ", count: 80) + "needle"
        let excerpt = HistorySearch.excerpt(of: line, matching: ["needle"], limit: 20)
        XCTAssertEqual(excerpt?.count, 21)
    }
}

/// The text read from an image is stored in the history entry and survives a restart.
final class CaptureHistoryTextTests: PrefsSandboxTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func encoded(_ entry: CaptureHistory.Entry) throws -> [String: Any] {
        let data = try JSONEncoder().encode(entry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEntryWithoutTextEncodesNoTextKey() throws {
        let entry = CaptureHistory.Entry(id: UUID(), path: "/tmp/a.png", kind: .image, date: Date(timeIntervalSince1970: 0), text: nil)
        XCTAssertNil(try encoded(entry)["text"])
    }

    func testEntryWithTextRoundTrips() throws {
        let entry = CaptureHistory.Entry(id: UUID(), path: "/tmp/a.png", kind: .image, date: Date(timeIntervalSince1970: 0), text: "Invoice 4821")
        XCTAssertEqual(try encoded(entry)["text"] as? String, "Invoice 4821")
        let decoded = try JSONDecoder().decode(CaptureHistory.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }

    func testIndexWrittenBeforeTextSearchStillDecodes() throws {
        let json = #"[{"id":"2F3C6B9E-0F58-4D0B-9F44-1E0D2C0A7E11","path":"/tmp/a.png","kind":"image","date":"2026-10-20T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([CaptureHistory.Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].text)
    }

    @MainActor func testAddedImageIsReadAndTheTextIsSavedAndReloaded() async throws {
        let index = folder.appendingPathComponent("history.json")
        let file = folder.appendingPathComponent("shot.png")
        try Data("x".utf8).write(to: file)

        let history = CaptureHistory(indexURL: index, capturesDirectory: folder)
        history.textReader = { _ in "Invoice 4821" }
        history.add(CaptureItem(url: file, kind: .image))
        try await waitUntil { history.recognizedText[file] == "Invoice 4821" }

        // The writer queue is serial and the index is written atomically: wait for the file to carry the text.
        try await waitUntil { (try? String(contentsOf: index, encoding: .utf8))?.contains("Invoice 4821") == true }
        let reloaded = CaptureHistory(indexURL: index, capturesDirectory: folder)
        XCTAssertEqual(reloaded.recognizedText[file], "Invoice 4821")
    }

    @MainActor func testVideosAreNeverRead() async throws {
        let file = folder.appendingPathComponent("clip.mov")
        try Data("x".utf8).write(to: file)
        let history = CaptureHistory(indexURL: folder.appendingPathComponent("history.json"), capturesDirectory: folder)
        history.textReader = { _ in XCTFail("a video was read"); return "" }
        history.add(CaptureItem(url: file, kind: .video))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(history.recognizedText[file])
    }

    @MainActor func testEditorSaveReadsTheImageAgain() async throws {
        let file = folder.appendingPathComponent("shot.png")
        try Data("x".utf8).write(to: file)
        let history = CaptureHistory(indexURL: folder.appendingPathComponent("history.json"), capturesDirectory: folder)
        let counter = Counter()
        history.textReader = { _ in "version \(counter.next())" }
        history.add(CaptureItem(url: file, kind: .image))
        try await waitUntil { history.recognizedText[file] == "version 1" }

        NotificationCenter.default.post(name: .captureUpdated, object: file)
        try await waitUntil { history.recognizedText[file] == "version 2" }
    }

    /// A recording pauses reading; it resumes when the recording ends, and the backlog is read too.
    @MainActor func testReadingWaitsWhileRecordingAndReadsTheBacklog() async throws {
        let index = folder.appendingPathComponent("history.json")
        let old = folder.appendingPathComponent("old.png"), new = folder.appendingPathComponent("new.png")
        for file in [old, new] { try Data("x".utf8).write(to: file) }
        let seed = CaptureHistory(indexURL: index, capturesDirectory: folder, isPaused: { true })
        seed.add(CaptureItem(url: old, kind: .image))
        try await waitUntil { (try? String(contentsOf: index, encoding: .utf8))?.contains("old.png") == true }

        var recording = true
        let history = CaptureHistory(indexURL: index, capturesDirectory: folder, isPaused: { recording })
        history.textReader = { "text of \($0.lastPathComponent)" }
        history.enqueueUnread()
        history.add(CaptureItem(url: new, kind: .image))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(history.recognizedText[old])
        XCTAssertNil(history.recognizedText[new])

        recording = false
        try await waitUntil(attempts: 400) { history.recognizedText[old] == "text of old.png" && history.recognizedText[new] == "text of new.png" }
    }

    @MainActor private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("condition not met in time")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
