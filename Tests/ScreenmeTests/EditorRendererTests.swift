import XCTest
@testable import Screenme

/// The editor draws a capture from full-resolution pixels whenever the screen shows them one to one.
final class EditorRendererTests: XCTestCase {
    @MainActor
    func testActualSizeOnRetinaDrawsTheFullResolutionImage() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 400, height: 300, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let source = ImageSource(image: image, unit: 2)
        // Actual size on a Retina screen: half a point per image pixel, two screen pixels per point.
        let actualSize = CGAffineTransform(scaleX: 0.5, y: 0.5)
        XCTAssertEqual(EditorRenderer.baseImage(source, transform: actualSize, baseScale: 2).width, 400)
        // Zoomed out to a quarter of the screen pixels, the half-resolution copy is enough.
        XCTAssertEqual(EditorRenderer.baseImage(source, transform: CGAffineTransform(scaleX: 0.2, y: 0.2), baseScale: 2).width, 200)
        // An export draws into pixels the transform already counts.
        XCTAssertEqual(EditorRenderer.baseImage(source, transform: .identity, baseScale: 1).width, 400)
    }
}
