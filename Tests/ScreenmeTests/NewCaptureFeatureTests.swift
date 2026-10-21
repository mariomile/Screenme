import XCTest
@testable import Screenme

/// Combine, watermark and hide-notch: the pure image work behind them.
final class NewCaptureFeatureTests: PrefsSandboxTestCase {
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

    private func solid(_ width: Int, _ height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func png(_ image: CGImage, _ name: String) -> URL {
        let url = folder.appendingPathComponent("\(name).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Gray value (0–255) of the pixel at (x, y), top-left origin.
    private func gray(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let data = CFDataGetBytePtr(image.dataProvider!.data!)!
        return data[y * image.bytesPerRow + x * image.bitsPerPixel / 8]
    }

    func testCombineSideBySideScalesToTheSmallestHeight() throws {
        let a = png(solid(100, 50, gray: 0), "a")
        let b = png(solid(40, 100, gray: 1), "b")
        let combined = try XCTUnwrap(ImageCombiner.combine([a, b], layout: .sideBySide))
        XCTAssertEqual(combined.height, 50)
        XCTAssertEqual(combined.width, 100 + 20)
        XCTAssertLessThan(gray(combined, 10, 25), 30)
        XCTAssertGreaterThan(gray(combined, 110, 25), 225)
    }

    func testCombineStackedPutsTheFirstImageOnTop() throws {
        let a = png(solid(80, 40, gray: 0), "a")
        let b = png(solid(160, 40, gray: 1), "b")
        let combined = try XCTUnwrap(ImageCombiner.combine([a, b], layout: .stacked))
        XCTAssertEqual(combined.width, 80)
        XCTAssertEqual(combined.height, 40 + 20)
        XCTAssertLessThan(gray(combined, 40, 5), 30)
        XCTAssertGreaterThan(gray(combined, 40, 55), 225)
    }

    func testCombineNeedsTwoImages() {
        XCTAssertNil(ImageCombiner.combine([png(solid(10, 10, gray: 0), "a")], layout: .stacked))
    }

    func testWatermarkIsOffByDefaultAndWhenTextIsBlank() {
        XCTAssertNil(Watermark.text)
        Prefs[Pref.watermarkEnabled] = true
        Prefs[Pref.watermarkText] = "   "
        XCTAssertNil(Watermark.text)
        let image = solid(50, 50, gray: 0)
        XCTAssertTrue(Watermark.applied(to: image) === image)
    }

    func testWatermarkDrawsInTheChosenCornerOnly() {
        Prefs[Pref.watermarkEnabled] = true
        Prefs[Pref.watermarkText] = "████████"
        Prefs[Pref.watermarkCorner] = .bottomRight
        let marked = Watermark.applied(to: solid(400, 300, gray: 0))
        XCTAssertEqual(marked.width, 400)
        let bottomRight = (300..<392).flatMap { x in (260..<292).map { y in gray(marked, x, y) } }.max()!
        let topLeft = (0..<100).flatMap { x in (0..<40).map { y in gray(marked, x, y) } }.max()!
        XCTAssertGreaterThan(bottomRight, 100)
        XCTAssertEqual(topLeft, 0)
    }

    func testWatermarkFrameKeepsTheMarginFromTheCorner() {
        Prefs[Pref.watermarkCorner] = .topLeft
        let frame = Watermark.frame(of: CGSize(width: 50, height: 10), in: CGRect(x: 0, y: 0, width: 200, height: 100), margin: 8)
        XCTAssertEqual(frame, CGRect(x: 8, y: 82, width: 50, height: 10))
    }
}
