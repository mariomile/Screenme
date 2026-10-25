import XCTest
@testable import Screenme

/// The pixel work `CaptureCoordinator.deliver` runs off the main thread.
final class DeliverTests: PrefsSandboxTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        CGImage.drawn(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }!
    }

    func testNotchCoverPaintsTheMenuBarBandBlackAtTheImageScale() throws {
        // A 100×50 point capture at 2x, the top 10 points under the menu bar.
        let cover = Notch.Cover(band: CGRect(x: 0, y: 40, width: 100, height: 10), captured: CGRect(x: 0, y: 0, width: 100, height: 50))
        let covered = cover.applied(to: image(width: 200, height: 100))
        let data = try XCTUnwrap(covered.dataProvider?.data as Data?)
        let row = covered.bytesPerRow
        // Bitmap rows run top to bottom in memory: row 0 is the top of the picture.
        XCTAssertEqual(data[0 * row], 0, "top row is black")
        XCTAssertEqual(data[19 * row], 0, "last covered row is black")
        XCTAssertEqual(data[20 * row], 255, "first row under the band stays white")
    }

    func testWriteToURLUsesTheFormatOfItsExtension() throws {
        let folder = try temporaryFolder()
        for (name, type) in [("shot.png", "public.png"), ("shot.jpg", "public.jpeg")] {
            let url = folder.appendingPathComponent(name)
            try Storage.write(image(width: 8, height: 8), to: url, scale: 2)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type)
        }
    }

    /// A Retina capture says so in its DPI; without it apps show it at twice its size on screen, blurred.
    @MainActor
    func testWriteRecordsPixelsPerPointAsDPI() throws {
        let folder = try temporaryFolder()
        for (name, scale) in [("retina.png", 2.0), ("retina.jpg", 2.0), ("standard.png", 1.0)] {
            let url = folder.appendingPathComponent(name)
            try Storage.write(image(width: 8, height: 8), to: url, scale: scale)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 72 * scale, name)
            XCTAssertEqual(ImageSource.unit(of: url), scale, name)
        }
    }
}
