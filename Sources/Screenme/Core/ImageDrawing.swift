import CoreGraphics

/// The one way to draw a new bitmap: 8-bit RGBA, premultiplied, bottom-left origin.
extension CGImage {
    /// A `width` by `height` pixel image in `colorSpace` with what `draw` puts in it. Nil when the context cannot be made.
    static func drawn(width: Int, height: Int, colorSpace: CGColorSpace, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        return context.makeImage()
    }

    /// This image with more drawn over it, at its own size and in its own color space (sRGB when it has none).
    /// `draw` gets the context and the image's bounds. Returns the image unchanged when it cannot be redrawn.
    func overdrawn(_ draw: (CGContext, CGRect) -> Void) -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return Self.drawn(width: width, height: height, colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.draw(self, in: bounds)
            draw(context, bounds)
        } ?? self
    }
}
