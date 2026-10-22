import Combine
import XCTest
@testable import Screenme

/// A drag changes the document many times; SwiftUI hears of it once, when the drag commits.
final class EditorPublishingTests: PrefsSandboxTestCase {
    @MainActor
    func testUpdatesPublishOnlyAtCommitUndoAndRedo() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 40, height: 30, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let source = ImageSource(image: image, unit: 1)
        let controller = EditorController(item: CaptureItem(url: URL(fileURLWithPath: "/tmp/editor-test.png"), kind: .image), source: source)
        var published = 0
        let sink = controller.objectWillChange.sink { published += 1 }
        defer { sink.cancel() }

        let before = controller.checkpoint()
        for step in 1...20 {
            controller.update { $0.outputScale = 1 + CGFloat(step) / 100 }
        }
        XCTAssertEqual(published, 0)

        controller.commit(since: before)
        XCTAssertEqual(published, 1)

        controller.undo()
        XCTAssertEqual(published, 2)
        controller.redo()
        XCTAssertEqual(published, 3)
    }

    @MainActor
    func testSliderStylesAreSavedAtCommitNotPerTick() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 40, height: 30, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let controller = EditorController(item: CaptureItem(url: URL(fileURLWithPath: "/tmp/editor-test.png"), kind: .image),
                                          source: ImageSource(image: image, unit: 1))
        controller.choose(.draw(.arrow))
        let before = controller.checkpoint()
        for step in 1...10 { controller.applyStyle { $0.opacity = 1 - Double(step) / 20 } }
        XCTAssertEqual(EditorStore.style(for: .arrow).opacity, 1)

        controller.commit(since: before)
        XCTAssertEqual(EditorStore.style(for: .arrow).opacity, 0.5, accuracy: 0.0001)
    }

    /// The Dim slider and the background sliders follow the same rule as the styles: nothing is published or saved
    /// per tick, both happen at commit.
    @MainActor
    func testDimAndBackgroundSlidersPublishAndSaveAtCommit() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 40, height: 30, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let controller = EditorController(item: CaptureItem(url: URL(fileURLWithPath: "/tmp/editor-test.png"), kind: .image),
                                          source: ImageSource(image: image, unit: 1))
        let savedDim = Prefs[Pref.editorSpotlightDim]
        let savedPadding = EditorStore.background().padding
        var published = 0
        let sink = controller.objectWillChange.sink { published += 1 }
        defer { sink.cancel() }

        let before = controller.checkpoint()
        for step in 1...10 {
            controller.applySpotlightDim(0.2 + Double(step) / 100)
            controller.applyBackground { $0.padding = Double(step) }
        }
        XCTAssertEqual(published, 0)
        XCTAssertEqual(Prefs[Pref.editorSpotlightDim], savedDim)
        XCTAssertEqual(EditorStore.background().padding, savedPadding)

        controller.commit(since: before)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(Prefs[Pref.editorSpotlightDim], 0.3, accuracy: 0.0001)
        XCTAssertEqual(EditorStore.background().padding, 10)
    }
}
