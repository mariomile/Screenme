import CoreGraphics
import XCTest
@testable import Screenme

/// The contact sheet: its size and layout for any number of keyframes, and what it draws.
final class ContactSheetTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5) -> CGImage {
        CGImage.drawn(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }!
    }

    private func cells(_ count: Int, width: Int = 320, height: Int = 240) -> [ContactSheet.Cell] {
        (0..<count).map {
            ContactSheet.Cell(image: image(width, height), number: $0 + 1, time: Double($0) * 2.5,
                              caption: String(repeating: "A long sentence that will not fit on two lines. ", count: 6))
        }
    }

    /// The RGBA bytes of the pixel at `x`, `y` from the top-left corner.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes
    }

    func testThreePerRowWithACaptionUnderEach() throws {
        let (size, boxes) = ContactSheet.layout(count: 7, boxHeight: 400)
        XCTAssertEqual(boxes.count, 7)
        XCTAssertEqual(size.width, 3 * 640 + 4 * ContactSheet.gap)
        XCTAssertEqual(size.height, 3 * (400 + ContactSheet.captionHeight) + 4 * ContactSheet.gap)
        XCTAssertEqual(Set(boxes.map(\.minX)).count, 3)
        XCTAssertEqual(Set(boxes.map(\.minY)).count, 3)
        XCTAssertEqual(boxes[3].minY, boxes[0].maxY + ContactSheet.captionHeight + ContactSheet.gap)
        XCTAssertTrue(boxes.allSatisfy { CGRect(origin: .zero, size: size).contains($0) })
    }

    func testFewKeyframesMakeANarrowerSheet() {
        XCTAssertEqual(ContactSheet.layout(count: 1, boxHeight: 400).size.width, 640 + 2 * ContactSheet.gap)
        XCTAssertEqual(ContactSheet.layout(count: 2, boxHeight: 400).size.width, 2 * 640 + 3 * ContactSheet.gap)
        XCTAssertEqual(ContactSheet.layout(count: 0, boxHeight: 400).boxes, [])
        XCTAssertNil(ContactSheet.render([]))
    }

    func testBoxesFollowTheFramesShape() {
        XCTAssertEqual(ContactSheet.boxHeight(for: [image(320, 240), image(320, 200), image(100, 100)]), 480)
        XCTAssertEqual(ContactSheet.boxHeight(for: [image(1000, 50)]), 200, "a strip still gets room")
        XCTAssertEqual(ContactSheet.boxHeight(for: [image(100, 400)]), 900, "a portrait is capped")
    }

    func testRendersEveryCellOnADarkBackground() throws {
        let sheet = try XCTUnwrap(ContactSheet.render(cells(5)))
        let (size, boxes) = ContactSheet.layout(count: 5, boxHeight: 480)
        XCTAssertEqual(CGSize(width: sheet.width, height: sheet.height), size)
        XCTAssertLessThan(pixel(sheet, 4, 4)[0], 40, "dark background")
        for box in boxes {
            // The frame fills its box (same shape); the badge is a white chip at the top left.
            XCTAssertEqual(Int(pixel(sheet, Int(box.midX), Int(box.midY))[0]), 146, accuracy: 6, "the gray frame")
            XCTAssertGreaterThan(pixel(sheet, Int(box.minX) + 16, Int(box.minY) + 16)[0], 230)
        }
    }

    func testThumbnailsAreScaledDownToTheirWidth() {
        let large = ContactSheet.thumbnail(image(1920, 1200))
        XCTAssertEqual(large.width, 640)
        XCTAssertEqual(large.height, 400)
        XCTAssertEqual(ContactSheet.thumbnail(image(320, 240)).width, 320)
        XCTAssertEqual(ContactSheet.fit(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       CGRect(x: 0, y: 25, width: 100, height: 50))
    }
}
