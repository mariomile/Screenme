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
}
