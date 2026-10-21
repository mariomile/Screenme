import CoreGraphics
import XCTest
@testable import Screenme

final class EdgeScannerTests: XCTestCase {
    /// A `width` x `height` buffer of one gray, with `fill` painting individual pixels.
    private func buffer(_ width: Int, _ height: Int, background: UInt8 = 255,
                        fill: (Int, Int) -> UInt8? = { _, _ in nil }) -> PixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = fill(x, y) ?? background
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return PixelBuffer(width: width, height: height, bytesPerRow: width * 4, bytes: bytes)
    }

    func testPlainBufferSpansTheWholeImage() {
        let spans = EdgeScanner.spans(in: buffer(40, 30), x: 10, y: 5)
        XCTAssertEqual(spans, EdgeScanner.Spans(minX: 0, maxX: 39, minY: 0, maxY: 29))
        XCTAssertEqual(spans?.width, 40)
        XCTAssertEqual(spans?.height, 30)
    }

    func testStopsAtTheEdgesOfABox() {
        // A dark box from (10, 5) to (29, 14) inclusive on white.
        let image = buffer(50, 30) { x, y in (10...29).contains(x) && (5...14).contains(y) ? 20 : nil }
        let inside = EdgeScanner.spans(in: image, x: 15, y: 8)
        XCTAssertEqual(inside, EdgeScanner.Spans(minX: 10, maxX: 29, minY: 5, maxY: 14))
        XCTAssertEqual(inside?.width, 20)
        XCTAssertEqual(inside?.height, 10)

        // Outside, on the box's row: the white run ends where the box begins.
        let left = EdgeScanner.spans(in: image, x: 3, y: 8)
        XCTAssertEqual(left?.minX, 0)
        XCTAssertEqual(left?.maxX, 9)
        XCTAssertEqual(left?.minY, 0)
        XCTAssertEqual(left?.maxY, 29)
    }

    func testOneThinLineIsAnEdge() {
        // A one-pixel vertical rule at x = 20.
        let image = buffer(40, 10) { x, _ in x == 20 ? 0 : nil }
        XCTAssertEqual(EdgeScanner.spans(in: image, x: 25, y: 4)?.minX, 21)
        XCTAssertEqual(EdgeScanner.spans(in: image, x: 5, y: 4)?.maxX, 19)
        let onLine = EdgeScanner.spans(in: image, x: 20, y: 4)
        XCTAssertEqual(onLine?.width, 1)
        XCTAssertEqual(onLine?.height, 10)
    }

    func testSmallDifferencesStayWithinTolerance() {
        // Noise of a few levels is not an edge; a step of 40 is.
        let image = buffer(30, 1) { x, _ in x < 15 ? UInt8(200 + x % 4) : 160 }
        XCTAssertEqual(EdgeScanner.spans(in: image, x: 2, y: 0)?.maxX, 14)
        XCTAssertEqual(EdgeScanner.spans(in: image, x: 2, y: 0, tolerance: 1)?.maxX, 3)
    }

    func testOutsideTheBufferIsNil() {
        XCTAssertNil(EdgeScanner.spans(in: buffer(10, 10), x: 10, y: 0))
        XCTAssertNil(EdgeScanner.spans(in: buffer(10, 10), x: 0, y: -1))
    }

    func testPixelBufferFromAnImageKeepsTopToBottomRows() throws {
        // Top half black, bottom half white, drawn in a bottom-left-origin context.
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        let pixels = try XCTUnwrap(PixelBuffer(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(pixels.bytes[0], 0)
        XCTAssertEqual(pixels.bytes[7 * pixels.bytesPerRow], 255)
        XCTAssertEqual(EdgeScanner.spans(in: pixels, x: 3, y: 1), EdgeScanner.Spans(minX: 0, maxX: 7, minY: 0, maxY: 3))
    }
}
