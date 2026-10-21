import CoreGraphics

/// Pixels in memory: 4 bytes per pixel in RGBA order, rows top to bottom.
struct PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    /// Draws `image` into RGBA bytes once, so scanning never decodes again.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: width * 4, bytes: bytes)
    }

    init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytes = bytes
    }
}

/// The run of same-colored pixels through a point, as Shottr's ruler finds it: from the pixel under the pointer
/// outward left, right, up and down until a pixel differs from it by more than `tolerance` in any channel.
enum EdgeScanner {
    /// Inclusive pixel bounds of the runs through one point: columns `minX...maxX` on its row,
    /// rows `minY...maxY` on its column. Top-left origin.
    struct Spans: Equatable {
        var minX: Int, maxX: Int
        var minY: Int, maxY: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Fine enough to stop at a one-step border, loose enough to cross JPEG noise and gradients' smallest steps.
    static let defaultTolerance = 12

    static func spans(in buffer: PixelBuffer, x: Int, y: Int, tolerance: Int = defaultTolerance) -> Spans? {
        guard (0..<buffer.width).contains(x), (0..<buffer.height).contains(y) else { return nil }
        let bytes = buffer.bytes
        let row = buffer.bytesPerRow
        let origin = y * row + x * 4
        func same(_ offset: Int) -> Bool {
            for channel in 0..<3 where abs(Int(bytes[offset + channel]) - Int(bytes[origin + channel])) > tolerance {
                return false
            }
            return true
        }
        var spans = Spans(minX: x, maxX: x, minY: y, maxY: y)
        while spans.minX > 0, same(y * row + (spans.minX - 1) * 4) { spans.minX -= 1 }
        while spans.maxX < buffer.width - 1, same(y * row + (spans.maxX + 1) * 4) { spans.maxX += 1 }
        while spans.minY > 0, same((spans.minY - 1) * row + x * 4) { spans.minY -= 1 }
        while spans.maxY < buffer.height - 1, same((spans.maxY + 1) * row + x * 4) { spans.maxY += 1 }
        return spans
    }
}
