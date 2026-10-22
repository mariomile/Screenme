import AVFoundation
import XCTest
@testable import Screenme

final class VideoCanvasTests: PrefsSandboxTestCase {
    private func settings(padding: Double, aspect: AspectPreset, radius: Double = 0) -> BackgroundSettings {
        var settings = BackgroundSettings()
        settings.enabled = true
        settings.padding = padding
        settings.aspect = aspect
        settings.cornerRadius = radius
        settings.shadow = 0
        settings.fill = .solid(RGBA(1, 0, 0))
        return settings
    }

    func testWithoutABackgroundTheVideoIsTheCanvas() {
        var off = settings(padding: 10, aspect: .square)
        off.enabled = false
        let layout = VideoCanvas.layout(videoSize: CGSize(width: 1920, height: 1080), settings: off)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(layout.contentRect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testPaddingIsAShareOfTheShorterSide() {
        let layout = VideoCanvas.layout(videoSize: CGSize(width: 1920, height: 1080), settings: settings(padding: 10, aspect: .auto))
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1920 + 216, height: 1080 + 216))
        XCTAssertEqual(layout.contentRect.origin, CGPoint(x: 108, y: 108))
    }

    func testAPortraitAspectFitsTheVideoInsideCentered() {
        let layout = VideoCanvas.layout(videoSize: CGSize(width: 1600, height: 900), settings: settings(padding: 0, aspect: .nineSixteen))
        XCTAssertEqual(layout.canvasSize.width, 1600)
        XCTAssertEqual(layout.canvasSize.height, (1600 * 16 / 9).rounded(.up), accuracy: 1)
        XCTAssertEqual(layout.contentRect.width, 1600)
        XCTAssertEqual(layout.contentRect.midY, layout.canvasSize.height / 2, accuracy: 1)
    }

    func testContentRectScalesToTheOutputWithTheOriginBottomLeft() {
        let layout = VideoCanvas.layout(videoSize: CGSize(width: 1000, height: 500), settings: settings(padding: 20, aspect: .square))
        // Padding 100 on each side, then squared: 1200 x 1200, the video at y 350 from the top.
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1200, height: 1200))
        let rect = VideoCanvas.contentRect(layout, renderSize: CGSize(width: 600, height: 600))
        XCTAssertEqual(rect, CGRect(x: 50, y: 175, width: 500, height: 250))
    }

    func testTheEditorsChoicesAreRememberedWithinTheVideoLimits() {
        let realStore = Prefs.store
        let suite = "dev.mariomiletta.ScreenmeTests.\(UUID().uuidString)"
        Prefs.store = UserDefaults(suiteName: suite)!
        defer {
            Prefs.store.removePersistentDomain(forName: suite)
            Prefs.store = realStore
        }
        XCTAssertEqual(VideoEditorDefaults.saved, VideoEditorDefaults(), "nothing saved yet")
        var wide = settings(padding: 35, aspect: .linkedin)
        wide.alignment = .topLeft
        var defaults = VideoEditorDefaults()
        defaults.canvas = wide
        defaults.zoomStrength = 9
        defaults.cursor.size = 0.2
        defaults.codec = .hevc
        defaults.gifFPS = 30
        VideoEditorDefaults.saved = defaults
        let saved = VideoEditorDefaults.saved
        XCTAssertEqual(saved.canvas.padding, 20)
        XCTAssertEqual(saved.canvas.aspect, .auto)
        XCTAssertEqual(saved.canvas.alignment, .center)
        XCTAssertTrue(saved.canvas.enabled)
        XCTAssertEqual(saved.zoomStrength, AutoZoom.strengthRange.upperBound)
        XCTAssertEqual(saved.cursor.size, CursorStyle.sizeRange.lowerBound)
        XCTAssertEqual(saved.codec, .hevc)
        XCTAssertEqual(saved.gif, .gif(fps: 30, maxWidth: 1280, quality: .high))
    }

    /// A green video on a red square canvas: red in the corners, green in the middle, the corners rounded off.
    @MainActor
    func testExportDrawsTheBackgroundAroundTheVideo() async throws {
        let video = try await TestVideo.makeOffMain(width: 320, height: 180, seconds: 1)
        defer { try? FileManager.default.removeItem(at: video) }
        let edit = VideoEdit(canvas: settings(padding: 20, aspect: .square, radius: 30))
        let source = VideoSource(size: CGSize(width: 320, height: 180), events: nil)
        let size = edit.outputSize(for: source, resolution: .original)
        XCTAssertEqual(size, CGSize(width: 392, height: 392))
        let renderer = edit.renderer(for: source, renderSize: size, duration: 1)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = try await VideoTranscoder.export(video, settings: VideoExportSettings(range: range, renderer: renderer, quality: .high, mute: true))
        defer { try? FileManager.default.removeItem(at: output) }

        let corner = try await TestVideo.pixel(of: output, at: 0.5, x: 4, y: 4)
        XCTAssertGreaterThan(corner.r, 200)
        XCTAssertLessThan(corner.g, 50)
        let middle = try await TestVideo.pixel(of: output, at: 0.5, x: 60, y: 120)
        XCTAssertLessThan(middle.r, 50)
        XCTAssertGreaterThan(middle.g, 120)
        // The video's top-left corner (36, 106) is rounded off: background shows there.
        let rounded = try await TestVideo.pixel(of: output, at: 0.5, x: 38, y: 108)
        XCTAssertGreaterThan(rounded.r, 150)
    }
}
