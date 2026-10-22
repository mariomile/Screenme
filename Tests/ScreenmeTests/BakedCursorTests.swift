import AVFoundation
import XCTest
@testable import Screenme

/// A Smooth cursor recording gets its cursor drawn into the file when it stops, so Copy, Save and drag are right,
/// and keeps the cursorless recording as a hidden source so the video editor can restyle the cursor.
final class BakedCursorTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup.removeAll()
        super.tearDown()
    }

    /// A recording filmed without the cursor, its pointer resting at 50, 60.
    private var events: RecordingEvents {
        var events = RecordingEvents(width: 200, height: 100, events: [])
        var track = CursorTrack(hidden: true)
        track.add(time: 0, x: 50, y: 60)
        track.add(time: 2, x: 50, y: 60)
        events.cursor = track
        return events
    }

    /// A recording's settings: the format, whether the cursor shows, and Smooth cursor.
    private func settings(_ format: RecordingFormat, showCursor: Bool = true, smoothCursor: Bool = true) -> RecordingSettings {
        RecordingSettings(format: format, fps: 30, quality: .high, showCursor: showCursor, smoothCursor: smoothCursor, highlightClicks: false,
                          showKeystrokes: false, microphone: false, microphoneID: "", systemAudio: false, webcam: false,
                          webcamSize: .medium, webcamID: "", countdown: 0, hideDesktopIcons: false, hideNotifications: false)
    }

    /// When a recording stops, a GIF recording becomes a GIF with the video editor's GIF settings, a Smooth cursor one
    /// gets its cursor drawn in as a full-size MP4 in the editor's codec, and anything else stays as it was filmed.
    func testWhatAStoppedRecordingBecomes() {
        var defaults = VideoEditorDefaults()
        defaults.codec = .hevc
        defaults.gifFPS = 10
        defaults.gifMaxWidth = 640
        defaults.cursor = CursorStyle(show: true, size: 2, clickHighlight: false, hideWhenIdle: true)

        XCTAssertEqual(StopRender.choose(for: settings(.gif), defaults: defaults, hasEvents: true),
                       .gif(.gif(fps: 10, maxWidth: 640, quality: .high)), "a GIF recording films its cursor")
        XCTAssertEqual(StopRender.choose(for: settings(.video), defaults: defaults, hasEvents: true),
                       .cursor(defaults.cursor, .mp4(codec: .hevc, quality: .high, resolution: .original, mute: false)))
        XCTAssertNil(StopRender.choose(for: settings(.video, smoothCursor: false), defaults: defaults, hasEvents: true), "the cursor was filmed")
        XCTAssertNil(StopRender.choose(for: settings(.video, showCursor: false), defaults: defaults, hasEvents: true), "no cursor at all")
        XCTAssertNil(StopRender.choose(for: settings(.video), defaults: defaults, hasEvents: false), "no cursor track to draw")
        defaults.cursor.show = false
        XCTAssertNil(StopRender.choose(for: settings(.video), defaults: defaults, hasEvents: true), "the editor hides the cursor")
    }

    @MainActor
    func testStoppingRendersTheCaptureAndKeepsTheCursorlessSource() async throws {
        let video = try await TestVideo.makeOffMain(width: 400, height: 200, seconds: 2)
        cleanup.append(video)
        let size = CGSize(width: 400, height: 200)

        let style = CursorStyle(show: true, size: 1.5, clickHighlight: true, hideWhenIdle: false)
        let result = try await BakedCursor.render(video, size: size, events: events, style: style,
                                                  spec: .mp4(codec: .h264, quality: .high, resolution: .original, mute: false))
        cleanup.append(result.item.url)
        cleanup.append(Sidecar.source.url(for: result.item.url))
        XCTAssertNotEqual(result.item.url, video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path), "the raw recording moved")
        let source = Sidecar.source.url(for: result.item.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the raw recording is kept as the source")
        XCTAssertEqual(source.lastPathComponent, ".\(result.item.url.lastPathComponent).screenme-source.mp4", "hidden, next to the capture")
        XCTAssertEqual(source.deletingLastPathComponent(), result.item.url.deletingLastPathComponent())
        XCTAssertEqual(result.events.cursor?.hidden, true, "it was filmed without the cursor")
        XCTAssertEqual(result.events.cursor?.bakedStyle, style, "the style drawn into the capture")
        XCTAssertNotNil(result.events.cursor, "the track stays for auto zoom")
        let rendered = try await TestVideo.size(of: result.item.url)
        XCTAssertEqual(rendered, size, "no background, same size")
        // Hotspot at (100, 120) pixels; 2 px per point. The arrow's black body runs down and right of it.
        let body = try await TestVideo.pixel(of: result.item.url, at: 1, x: 100 + 6, y: 120 + 14)
        XCTAssertLessThan(body.g, 100, "the arrow, not the green video")
        let far = try await TestVideo.pixel(of: result.item.url, at: 1, x: 380, y: 20)
        XCTAssertGreaterThan(far.g, 120, "the rest is the recording")
        let sourceBody = try await TestVideo.pixel(of: source, at: 1, x: 100 + 6, y: 120 + 14)
        XCTAssertGreaterThan(sourceBody.g, 120, "the source has no cursor")
    }
}
