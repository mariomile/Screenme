import AppKit
import QuartzCore

/// The magnifier: 15 x 15 screen pixels blown up 9x with a pixel grid, the center pixel marked,
/// and the cursor coordinates underneath.
final class Loupe {
    static let cells = 15
    static let cell: CGFloat = 9
    private static let inset: CGFloat = 2.5
    private static let side = CGFloat(cells) * cell + inset * 2
    private static let radius: CGFloat = 16

    let layer = CALayer()
    private let frameLayer = CALayer()
    private let host = CALayer()
    private let image = CALayer()
    private let grid = CAShapeLayer()
    private let centerOuter = CALayer()
    private let centerInner = CALayer()
    private let coordinates: Pill
    private let size: Pill
    private var showsSize = false

    init(scale: CGFloat) {
        coordinates = Pill(scale: scale, fontSize: 11.5)
        size = Pill(scale: scale, fontSize: 11.5)
        let side = Self.side

        frameLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        frameLayer.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        frameLayer.cornerRadius = Self.radius
        frameLayer.borderWidth = Self.inset
        frameLayer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.4
        frameLayer.shadowRadius = 10
        frameLayer.shadowOffset = CGSize(width: 0, height: -3)
        frameLayer.shadowPath = CGPath(roundedRect: frameLayer.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)

        host.frame = CGRect(x: Self.inset, y: Self.inset, width: side - Self.inset * 2, height: side - Self.inset * 2)
        host.cornerRadius = Self.radius - Self.inset
        host.masksToBounds = true

        image.frame = host.bounds
        image.magnificationFilter = .nearest
        image.minificationFilter = .nearest
        image.contentsGravity = .resize

        let path = CGMutablePath()
        let extent = CGFloat(Self.cells) * Self.cell
        for index in 1..<Self.cells {
            let offset = CGFloat(index) * Self.cell
            path.move(to: CGPoint(x: offset, y: 0)); path.addLine(to: CGPoint(x: offset, y: extent))
            path.move(to: CGPoint(x: 0, y: offset)); path.addLine(to: CGPoint(x: extent, y: offset))
        }
        grid.frame = host.bounds
        grid.path = path
        grid.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
        grid.lineWidth = 0.5

        let middle = CGFloat(Self.cells / 2) * Self.cell
        centerInner.frame = CGRect(x: middle, y: middle, width: Self.cell, height: Self.cell)
        centerInner.borderWidth = 1.5
        centerInner.borderColor = NSColor.white.cgColor
        centerOuter.frame = centerInner.frame.insetBy(dx: -1, dy: -1)
        centerOuter.borderWidth = 1
        centerOuter.borderColor = NSColor.black.withAlphaComponent(0.8).cgColor

        host.addSublayer(image)
        host.addSublayer(grid)
        host.addSublayer(centerOuter)
        host.addSublayer(centerInner)
        frameLayer.addSublayer(host)
        layer.addSublayer(frameLayer)
        layer.addSublayer(coordinates.layer)
        layer.addSublayer(size.layer)
    }

    /// Size of the whole block (loupe plus captions) for the current captions.
    var blockSize: CGSize {
        let captions = coordinates.size.height + (showsSize ? size.size.height + 4 : 0)
        return CGSize(width: Self.side, height: Self.side + 8 + captions)
    }

    func update(sample: CGImage?, coordinates text: String, size sizeText: String?) {
        if let sample { image.contents = sample }
        coordinates.set(text)
        showsSize = sizeText != nil
        size.layer.isHidden = !showsSize
        if let sizeText { size.set(sizeText) }

        let block = blockSize
        layer.bounds = CGRect(origin: .zero, size: block)
        frameLayer.position = CGPoint(x: Self.side / 2, y: block.height - Self.side / 2)
        let coordinatesY = frameLayer.frame.minY - 8 - coordinates.size.height
        coordinates.layer.frame = CGRect(x: ((Self.side - coordinates.size.width) / 2).rounded(), y: coordinatesY.rounded(),
                                         width: coordinates.size.width, height: coordinates.size.height)
        if showsSize {
            let y = coordinatesY - 4 - size.size.height
            size.layer.frame = CGRect(x: ((Self.side - size.size.width) / 2).rounded(), y: y.rounded(),
                                      width: size.size.width, height: size.size.height)
        }
    }

    /// The `cells` x `cells` pixels around (centerX, centerY), in image pixel coordinates (top-left origin).
    /// Pixels outside the image stay dark.
    static func sample(_ image: CGImage, centerX: Int, centerY: Int) -> CGImage? {
        let n = cells
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = image.colorSpace.flatMap {
            CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info)
        } ?? CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        guard let context else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: n, height: n))

        let wanted = CGRect(x: centerX - n / 2, y: centerY - n / 2, width: n, height: n)
        let visible = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isNull, let part = image.cropping(to: visible) {
            // Image rows run top to bottom, the bitmap context's run bottom to top.
            context.draw(part, in: CGRect(x: visible.minX - wanted.minX,
                                          y: CGFloat(n) - (visible.minY - wanted.minY) - visible.height,
                                          width: visible.width, height: visible.height))
        }
        return context.makeImage()
    }
}
