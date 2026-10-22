import AVFoundation
import XCTest
@testable import Screenme

final class VideoExportTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup.removeAll()
        super.tearDown()
    }

    private func video(width: Int, height: Int, seconds: Double) async throws -> URL {
        let url = try await TestVideo.makeOffMain(width: width, height: height, seconds: seconds)
        cleanup.append(url)
        return url
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    func testExportTrimsScalesAndSpeedsUp() async throws {
        let source = try await video(width: 640, height: 360, seconds: 4)
        let renderer = FrameRenderer(renderSize: CGSize(width: 320, height: 180), timeOffset: 1, speed: 2)
        let output = try await VideoTranscoder.export(source, settings: VideoExportSettings(range: range(1, 3), renderer: renderer,
                                                                                           quality: .medium, mute: true))
        cleanup.append(output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1, "2 s of video at 2x")
        let size = try await TestVideo.size(of: output)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        let pixel = try await TestVideo.pixel(of: output, at: 0.5, x: 5, y: 5)
        XCTAssertLessThan(pixel.r, 40)
        XCTAssertGreaterThan(pixel.g, 120)
    }

    /// A 30 s 1080p recording must export in under 1.5x its length (45 s) on this Mac, with every layer on.
    func testExportOf30Seconds1080pIsFasterThanOneAndAHalfTimesRealtime() async throws {
        let source = try await video(width: 1920, height: 1080, seconds: 30)
        let renderer = await TimingFixture.renderer(sourceSize: CGSize(width: 1920, height: 1080), duration: 30)
        let started = Date()
        let output = try await VideoTranscoder.export(source, settings: VideoExportSettings(range: range(0, 30), renderer: renderer,
                                                                                           quality: .high, mute: true))
        let elapsed = Date().timeIntervalSince(started)
        cleanup.append(output)
        print(String(format: "EXPORT TIME 30 s 1080p: %.2f s (%.2fx realtime)", elapsed, elapsed / 30))
        XCTAssertLessThan(elapsed, 45)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 30, accuracy: 0.1)
    }

    func testSpeedUpShortensTheSoundTooAndMuteDropsIt() async throws {
        let source = try TestVideo.make(width: 320, height: 180, seconds: 4, tone: true)
        cleanup.append(source)
        let renderer = FrameRenderer(renderSize: CGSize(width: 320, height: 180), timeOffset: 0, speed: 2)
        let output = try await VideoTranscoder.export(source, settings: VideoExportSettings(range: range(0, 4), renderer: renderer,
                                                                                           quality: .medium, mute: false))
        cleanup.append(output)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let audioLength = try await audio[0].load(.timeRange).duration.seconds
        XCTAssertEqual(audioLength, 2, accuracy: 0.15)

        let muted = try await VideoTranscoder.export(source, settings: VideoExportSettings(range: range(1, 3), renderer: FrameRenderer(renderSize: CGSize(width: 320, height: 180), timeOffset: 1),
                                                                                          quality: .medium, mute: true))
        cleanup.append(muted)
        let mutedAudio = try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio)
        XCTAssertTrue(mutedAudio.isEmpty)
        let mutedLength = try await AVURLAsset(url: muted).load(.duration).seconds
        XCTAssertEqual(mutedLength, 2, accuracy: 0.1)
    }

    func testGIFMaxWidthScalesDownOnly() {
        XCTAssertEqual(ExportResolution.fitting(CGSize(width: 1920, height: 1080), maxWidth: 800), CGSize(width: 800, height: 450))
        XCTAssertEqual(ExportResolution.fitting(CGSize(width: 640, height: 360), maxWidth: 1280), CGSize(width: 640, height: 360))
        XCTAssertEqual(ExportResolution.fitting(CGSize(width: 1921, height: 1081), maxWidth: 0), CGSize(width: 1920, height: 1080), "even")
    }

    func testASpecSizesItsOutput() {
        let canvas = CGSize(width: 1921, height: 1081)
        XCTAssertEqual(ExportSpec.mp4(codec: .h264, quality: .high, resolution: .original, mute: false).outputSize(for: canvas),
                       CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportSpec.mp4(codec: .h264, quality: .high, resolution: .p720, mute: false).outputSize(for: CGSize(width: 1920, height: 1080)),
                       CGSize(width: 1280, height: 720))
        XCTAssertEqual(ExportSpec.gif(fps: 15, maxWidth: 800, quality: .high).outputSize(for: canvas), CGSize(width: 800, height: 450))
    }

    /// A GIF recording is converted with the video editor's GIF settings when it stops.
    @MainActor
    func testTheOneOutputWritesAGIFAtItsMaxWidth() async throws {
        let source = try await video(width: 640, height: 360, seconds: 1)
        let output = try await VideoOutput.render(source, source: VideoSource(size: CGSize(width: 640, height: 360), events: nil),
                                                  edit: VideoEdit(), spec: .gif(fps: 10, maxWidth: 320, quality: .low))
        cleanup.append(output.url)
        XCTAssertEqual(output.kind, .gif)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 10)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width, 320)
    }

    func testHEVCExport() async throws {
        let source = try await video(width: 640, height: 360, seconds: 1)
        let renderer = FrameRenderer(renderSize: CGSize(width: 640, height: 360))
        let output = try await VideoTranscoder.export(source, settings: VideoExportSettings(range: range(0, 1), renderer: renderer,
                                                                                           quality: .high, codec: .hevc, mute: true))
        cleanup.append(output)
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first
        let format = try await track?.load(.formatDescriptions).first
        XCTAssertEqual(format.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_HEVC)
    }

    func testGIFExportGoesThroughTheComposition() async throws {
        let source = try await video(width: 320, height: 180, seconds: 1)
        let renderer = FrameRenderer(renderSize: CGSize(width: 160, height: 90))
        let output = try await GIFExporter.export(source, range: range(0, 1), renderer: renderer, fps: 10, quality: .low) { _ in }
        cleanup.append(output)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(image), 1)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertEqual(first.width, 160)
        XCTAssertEqual(first.height, 90)
    }

    func testGIFExportOfAGeneratedVideoDecodesWithOneFramePerTick() async throws {
        let source = try await video(width: 320, height: 180, seconds: 1)
        let renderer = FrameRenderer(renderSize: CGSize(width: 160, height: 90))
        let output = try await GIFExporter.export(source, range: range(0, 1), renderer: renderer, fps: 10, quality: .medium) { _ in }
        cleanup.append(output)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 10, "1 s at 10 fps, and the moving block changes every tick")
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 9, nil))
        XCTAssertEqual(last.width, 160)
        XCTAssertEqual(last.height, 90)
    }
}

/// The renderer the timing test exports with: a gradient background with padding, corners and shadow,
/// an automatic zoom every 6 seconds following a cursor that circles the screen, and that cursor drawn smooth
/// with its click highlights.
@MainActor
enum TimingFixture {
    static func renderer(sourceSize: CGSize, duration: Double) -> FrameRenderer {
        var track = CursorTrack(hidden: true)
        var clicks: [RecordingEvent] = []
        let points = CGSize(width: sourceSize.width / 2, height: sourceSize.height / 2)
        for i in 0...Int(duration * 60) {
            let t = Double(i) / 60
            track.add(time: t, x: points.width * (0.5 + 0.35 * cos(t)), y: points.height * (0.5 + 0.35 * sin(t)))
        }
        for t in stride(from: 3.0, to: duration, by: 6) {
            clicks.append(.click(at: CGPoint(x: points.width * (0.5 + 0.35 * cos(t)), y: points.height * (0.5 + 0.35 * sin(t))),
                                 right: false, time: t))
        }
        track.down = clicks.map(\.time)
        track.up = clicks.map { $0.time + 0.2 }
        var events = RecordingEvents(width: points.width, height: points.height, events: clicks)
        events.cursor = track
        let source = VideoSource(size: sourceSize, events: events)

        var edit = VideoEdit()
        edit.canvas.enabled = true
        edit.canvas.fill = .gradient("ocean")
        edit.canvas.padding = 8
        edit.canvas.aspect = .sixteenNine
        edit.zooms = AutoZoom.segments(for: events, duration: duration)
        return edit.renderer(for: source, renderSize: edit.outputSize(for: source, resolution: .p1080), duration: duration)
    }
}
