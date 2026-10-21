import ImageIO
import XCTest
@testable import Screenme

final class GIFEncoderTests: XCTestCase {
    private let width = 16
    private let height = 12

    /// An RGBX frame of one colour, with an optional differently coloured block in the top-left corner.
    private func frame(_ color: (UInt8, UInt8, UInt8), block: (UInt8, UInt8, UInt8)? = nil) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = (block != nil && x < 4 && y < 4) ? block! : color
                let o = (y * width + x) * 4
                pixels[o] = c.0; pixels[o + 1] = c.1; pixels[o + 2] = c.2
            }
        }
        return pixels
    }

    private let red: (UInt8, UInt8, UInt8) = (255, 0, 0)
    private let green: (UInt8, UInt8, UInt8) = (0, 255, 0)
    private let blue: (UInt8, UInt8, UInt8) = (0, 0, 255)

    /// Encodes `frames` (pixels, start time) and returns the file bytes.
    private func encode(_ frames: [([UInt8], Double)], endTime: Double, dither: Bool = false) -> Data {
        let builder = GIFPaletteBuilder()
        for (pixels, _) in frames {
            pixels.withUnsafeBufferPointer { builder.add($0.baseAddress!, width: width, height: height, bytesPerRow: width * 4) }
        }
        let encoder = GIFEncoder(width: width, height: height, palette: builder.build(colors: 64), dither: dither)
        for (pixels, time) in frames {
            pixels.withUnsafeBufferPointer { encoder.add($0.baseAddress!, bytesPerRow: width * 4, at: time) }
        }
        return encoder.finish(endTime: endTime)
    }

    private func delays(_ source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? -1
        }
    }

    private func rgb(of image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testWritesAValidAnimatedGIF() throws {
        let data = encode([(frame(red), 0), (frame(green), 0.1), (frame(blue), 0.3)], endTime: 0.5)
        XCTAssertEqual(String(decoding: data.prefix(6), as: UTF8.self), "GIF89a")
        XCTAssertEqual(data.last, 0x3B, "trailer")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        for index in 0..<3 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
        }
    }

    func testFrameDelaysFollowTimestamps() throws {
        let data = encode([(frame(red), 0), (frame(green), 0.1), (frame(blue), 0.3)], endTime: 0.5)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let result = delays(source)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 0.10, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.20, accuracy: 0.001)
        XCTAssertEqual(result[2], 0.20, accuracy: 0.001)
    }

    func testIdenticalFrameOnlyExtendsPreviousDelay() throws {
        let data = encode([(frame(red), 0), (frame(red), 0.1), (frame(green), 0.4)], endTime: 0.5)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let result = delays(source)
        XCTAssertEqual(result[0], 0.40, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.10, accuracy: 0.001)
    }

    func testVeryShortDelayIsClampedToTwoCentiseconds() throws {
        let data = encode([(frame(red), 0), (frame(green), 0.001)], endTime: 0.5)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(delays(source)[0], 0.02, accuracy: 0.001)
    }

    func testDecodedPixelsMatchSourceColours() throws {
        // The second frame changes only a corner block, so it is stored as a sub-rectangle with transparent holes.
        let data = encode([(frame(red), 0), (frame(red, block: blue), 0.2)], endTime: 0.4)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))

        let a = rgb(of: first, x: 8, y: 8)
        XCTAssertGreaterThan(a.0, 200); XCTAssertLessThan(a.1, 60); XCTAssertLessThan(a.2, 60)
        let corner = rgb(of: second, x: 1, y: 1)
        XCTAssertLessThan(corner.0, 60); XCTAssertLessThan(corner.1, 60); XCTAssertGreaterThan(corner.2, 200)
        let rest = rgb(of: second, x: 8, y: 8)
        XCTAssertGreaterThan(rest.0, 200, "unchanged pixels must show the previous frame through the transparent index")
    }

    func testPaletteHonoursRequestedColourCount() {
        let builder = GIFPaletteBuilder()
        let pixels = frame(red, block: blue)
        pixels.withUnsafeBufferPointer { builder.add($0.baseAddress!, width: width, height: height, bytesPerRow: width * 4) }
        let palette = builder.build(colors: 2)
        XCTAssertEqual(palette.rgb.count, 256 * 3)
        XCTAssertEqual(palette.lookup.count, 32768)
        XCTAssertNotEqual(palette.lookup[31 << 10], palette.lookup[31], "red and blue land on different entries")
        XCTAssertTrue(palette.lookup.allSatisfy { $0 < 2 })
    }
}
