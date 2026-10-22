import XCTest
@testable import Screenme

/// The redacted copy that Copy for AI and Share send: pixels under the boxes change, everything else stays.
@MainActor
final class RedactionTests: XCTestCase {
    private let width = 200, height = 100

    /// A noisy image, so a mosaic over it is never the same pixels.
    private func noisyImage() throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 7 + y * 13) % 256)
                pixels[i + 1] = UInt8((x * 11 + y * 3) % 256)
                pixels[i + 2] = UInt8((x * 5 + y * 17) % 256)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(pixels[i..<i + 4])
    }

    func testPixelsInsideTheBoxChangeAndOutsideStay() throws {
        let original = try noisyImage()
        let box = CGRect(x: 40, y: 30, width: 60, height: 30) // top-left origin; the margin is 6 pixels
        let redacted = try XCTUnwrap(Redaction.redacted(original, boxes: [box], unit: 1))
        XCTAssertEqual(redacted.width, width)
        XCTAssertEqual(redacted.height, height)
        let before = try rgba(original), after = try rgba(redacted)

        for point in [(45, 35), (70, 45), (95, 55), (36, 32), (104, 58)] {
            XCTAssertNotEqual(pixel(after, point.0, point.1), pixel(before, point.0, point.1), "inside at \(point)")
        }
        for point in [(0, 0), (10, 90), (190, 10), (199, 99), (150, 45), (70, 10), (70, 80), (20, 45), (120, 45)] {
            XCTAssertEqual(pixel(after, point.0, point.1), pixel(before, point.0, point.1), "outside at \(point)")
        }
    }

    func testNoBoxesLeavesEveryPixel() throws {
        let original = try noisyImage()
        let redacted = try XCTUnwrap(Redaction.redacted(original, boxes: [], unit: 1))
        XCTAssertEqual(try rgba(redacted), try rgba(original))
    }

    func testMarginIsCutToTheImage() throws {
        let original = try noisyImage()
        let redacted = try XCTUnwrap(Redaction.redacted(original, boxes: [CGRect(x: 0, y: 0, width: 20, height: 10)], unit: 1))
        XCTAssertNotEqual(pixel(try rgba(redacted), 0, 0), pixel(try rgba(original), 0, 0))
    }

    func testSharingTheSameCaptureAgainReusesItsFolder() throws {
        let image = try noisyImage()
        let name = "Screenme-test-\(UUID().uuidString).png"
        let original = URL(fileURLWithPath: "/captures/" + name)
        let first = try XCTUnwrap(Redaction.write(image, like: original))
        let second = try XCTUnwrap(Redaction.write(image, like: original))
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path), [name])
    }

    func testStaleCopiesGoAfterADayAndFreshOnesStay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RedactionStale-\(UUID().uuidString)")
        let old = root.appendingPathComponent("old"), fresh = root.appendingPathComponent("fresh")
        for folder in [old, fresh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: old.path)
        Redaction.removeStaleCopies(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
