import XCTest
@testable import Screenme

/// At actual size the canvas starts on a whole point, so each image pixel lands on one screen pixel.
final class ViewportTests: XCTestCase {
    func testCanvasOriginSitsOnWholePoints() {
        // An odd pixel width at 2x would otherwise put the canvas a quarter point, half a screen pixel, off.
        var viewport = Viewport(layout: Layout.make(crop: CGRect(x: 0, y: 0, width: 1885, height: 1193), background: nil), unit: 2)
        viewport.viewSize = CGSize(width: 1201, height: 900)
        viewport.fit()
        XCTAssertEqual(viewport.zoom, viewport.actualSize)
        viewport.setPan(CGPoint(x: 0.3, y: -0.7))
        let origin = viewport.canvasOrigin
        XCTAssertEqual(origin.x, origin.x.rounded())
        XCTAssertEqual(origin.y, origin.y.rounded())
    }
}
