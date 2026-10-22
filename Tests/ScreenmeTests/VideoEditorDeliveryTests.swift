import AVFoundation
import XCTest
@testable import Screenme

/// The video editor hands its exports to History and, when asked, the clipboard. It never runs the
/// after-recording actions: those would open another editor on the export or save it a second time.
@MainActor
final class VideoEditorDeliveryTests: PrefsSandboxTestCase {
    private var recorded: [URL] = []
    private var copied: [URL] = []

    private var spy: VideoEditorDelivery {
        VideoEditorDelivery(record: { [unowned self] in recorded.append($0.url) }, copy: { [unowned self] in copied.append($0.url) })
    }

    private let item = CaptureItem(url: URL(fileURLWithPath: "/tmp/export.mp4"), kind: .video)

    func testDoneRecordsTheExportAndCopiesItOnlyWhenAsked() {
        Prefs[Pref.afterRecordingCopy] = false
        spy.finished(item)
        XCTAssertEqual(recorded, [item.url])
        XCTAssertEqual(copied, [])

        Prefs[Pref.afterRecordingCopy] = true
        spy.finished(item)
        XCTAssertEqual(recorded, [item.url, item.url])
        XCTAssertEqual(copied, [item.url])
    }

    func testSaveOnlyRecords() {
        Prefs[Pref.afterRecordingCopy] = true
        spy.saved(item)
        XCTAssertEqual(recorded, [item.url])
        XCTAssertEqual(copied, [])
    }

    /// Done in the editor, with every after-recording action on: the export is recorded once and copied once,
    /// and nothing else runs (no editor opens on it, no second save).
    func testTheEditorsDoneGoesThroughTheDeliveryOnly() async throws {
        Prefs[Pref.afterRecordingOpenEditor] = true
        Prefs[Pref.afterRecordingSave] = true
        Prefs[Pref.afterRecordingQuickAccess] = true
        Prefs[Pref.afterRecordingCopy] = true
        let video = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        defer { try? FileManager.default.removeItem(at: video) }
        let saveFolder = FileManager.default.temporaryDirectory.appendingPathComponent("screenme-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saveFolder) }
        Prefs[Pref.saveDirectory] = saveFolder.path

        let model = VideoEditorModel(item: CaptureItem(url: video, kind: .video), delivery: spy)
        for _ in 0..<200 where model.duration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(model.duration, 0)
        model.edit.speed = 2
        model.perform(.done)
        for _ in 0..<500 where recorded.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(copied, recorded)
        XCTAssertNotEqual(recorded.first, video, "a new file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saveFolder.path), [], "not saved to the folder")
        recorded.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
