import AppKit
import CoreText
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

    func testSharingTheSameCaptureAgainOverwritesItsCopy() throws {
        let image = try noisyImage()
        let name = "Screenme-test-\(UUID().uuidString).png"
        let original = URL(fileURLWithPath: "/captures/" + name)
        let first = try XCTUnwrap(Redaction.write(image, like: original))
        let second = try XCTUnwrap(Redaction.write(image, like: original))
        defer { try? FileManager.default.removeItem(at: first) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, TemporaryCopies.folder.standardizedFileURL)
        XCTAssertNotNil(ImageSource.load(url: first), "a readable PNG")
    }

    func testStaleCopiesGoAfterADayAndFreshOnesStay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopiesStale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(TemporaryCopies.write(Data("old".utf8), named: "old.png", in: root))
        let fresh = try XCTUnwrap(TemporaryCopies.write(Data("fresh".utf8), named: "fresh.png", in: root))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: old.path)
        TemporaryCopies.removeStale(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a copy from today stays: Copy for AI's text still names it")
    }
}

/// What Share and Upload & Copy Link send. With Hide sensitive info when sharing on, never the capture unchecked:
/// when it cannot be read, checked or its redacted copy written, nothing is shared.
@MainActor
final class ShareableCopyTests: PrefsSandboxTestCase {
    /// A white picture with `text` in large black letters, written as a PNG named `name`.
    private func capture(_ text: String, named name: String = "shot.png") throws -> URL {
        let width = 900, height = 120
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black,
        ]))
        context.textPosition = CGPoint(x: 24, y: 40)
        CTLineDraw(line, context)
        let url = try temporaryFolder().appendingPathComponent(name)
        try XCTUnwrap(context.makeImage()).writePNG(to: url)
        return url
    }

    private func unreadableCapture() throws -> URL {
        let url = try temporaryFolder().appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        return url
    }

    func testWithTheSettingOffTheCaptureGoesAsItIs() async throws {
        let url = try unreadableCapture()
        let shared = try await Redaction.shareableCopy(of: url)
        XCTAssertEqual(shared.url, url)
        XCTAssertEqual(shared.hidden, 0)
    }

    func testAnImageThatCannotBeReadIsNotShared() async throws {
        Prefs[Pref.hideSensitiveWhenSharing] = true
        do {
            _ = try await Redaction.shareableCopy(of: try unreadableCapture())
            XCTFail("an image that cannot be checked is not shared")
        } catch {
            XCTAssertEqual(error as? Redaction.Failure, .unchecked)
            XCTAssertEqual(error.localizedDescription, "Could not check the image for sensitive info, so nothing was shared")
        }
    }

    func testWithNothingToHideTheCaptureItselfIsShared() async throws {
        Prefs[Pref.hideSensitiveWhenSharing] = true
        let url = try capture("Quarterly plan")
        let shared = try await Redaction.shareableCopy(of: url)
        XCTAssertEqual(shared.url, url)
        XCTAssertEqual(shared.hidden, 0)
    }

    func testARedactedCopyThatCannotBeWrittenIsNotShared() async throws {
        Prefs[Pref.hideSensitiveWhenSharing] = true
        let url = try capture("mario.rossi@example.com", named: "Screenme-test-\(UUID().uuidString).png")
        let redacted = try await Redaction.shareableCopy(of: url)
        XCTAssertEqual(redacted.hidden, 1, "the email is found")
        XCTAssertNotEqual(redacted.url, url)

        // A folder where the copy goes: it cannot be written.
        try FileManager.default.removeItem(at: redacted.url)
        try FileManager.default.createDirectory(at: redacted.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: redacted.url) }
        do {
            _ = try await Redaction.shareableCopy(of: url)
            XCTFail("the capture is not shared when its redacted copy cannot be written")
        } catch {
            XCTAssertEqual(error as? Redaction.Failure, .notWritten)
        }
    }
}
