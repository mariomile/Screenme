import AppKit
import CoreImage
import ImageIO

/// The image being edited, plus the derived pixels the editor needs often:
/// a pyramid of smaller copies for fast zoomed-out drawing and cached redaction patches.
@MainActor
final class ImageSource {
    let image: CGImage
    let size: CGSize
    /// Pixels per point of the captured image (2 for a retina capture).
    let unit: CGFloat
    let colorSpace: CGColorSpace

    private var mips: [CGImage] = []
    private var redactions: [RedactKey: CGImage] = [:]
    /// The cached redaction keys, least recently used first.
    private var redactionUse: [RedactKey] = []
    private static let redactionLimit = 48

    private struct RedactKey: Hashable {
        var blur: Bool
        var x: Int, y: Int, w: Int, h: Int
        var amount: Int
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(image: CGImage, unit: CGFloat) {
        self.image = image
        self.size = CGSize(width: image.width, height: image.height)
        self.unit = unit
        if let cs = image.colorSpace, cs.model == .rgb, Self.canCreateContext(with: cs) {
            colorSpace = cs
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    private static func canCreateContext(with cs: CGColorSpace) -> Bool {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) != nil
    }

    static func load(url: URL) -> ImageSource? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return ImageSource(image: image, unit: unit(of: src))
    }

    /// Pixels per point of an image file, from its DPI; files without one count as captured with the Retina setting.
    static func unit(of url: URL) -> CGFloat {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(unit(of:)) ?? 1
    }

    private static func unit(of src: CGImageSource) -> CGFloat {
        var unit: CGFloat = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 1 {
            unit = max(1, CGFloat(dpi / 72).rounded())
        }
        if unit == 0 {
            unit = Prefs[Pref.retinaResolution] ? (NSScreen.main?.backingScaleFactor ?? 2) : 1
        }
        return min(unit, 4)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Pyramid

    /// The smallest copy that still has at least `scale` device pixels per image pixel.
    func level(forScale scale: CGFloat) -> CGImage {
        var level = 0
        var s: CGFloat = 1
        while scale <= s * 0.5 && level < 6 && min(size.width, size.height) * s > 64 {
            level += 1
            s *= 0.5
        }
        guard level > 0 else { return image }
        while mips.count < level {
            let previous = mips.last ?? image
            let w = max(1, previous.width / 2), h = max(1, previous.height / 2)
            guard let ctx = makeContext(width: w, height: h, opaque: false) else { return previous }
            ctx.interpolationQuality = .high
            ctx.draw(previous, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let next = ctx.makeImage() else { return previous }
            mips.append(next)
        }
        return mips[level - 1]
    }

    func makeContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
    }

    // MARK: Redactions

    /// A small mosaic of `rect`. Draw it stretched over the rect with interpolation off.
    func pixelated(_ rect: CGRect, block: CGFloat) -> (CGImage, CGRect)? {
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let key = RedactKey(blur: false, x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height), amount: Int(block * 4))
        if let cached = cached(key) { return (cached, r) }
        guard let crop = image.cropping(to: r) else { return nil }
        let bw = max(1, Int((r.width / max(block, 1)).rounded(.up)))
        let bh = max(1, Int((r.height / max(block, 1)).rounded(.up)))
        guard let ctx = makeContext(width: bw, height: bh, opaque: false) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: bw, height: bh))
        guard let small = ctx.makeImage() else { return nil }
        store(small, for: key)
        return (small, r)
    }

    func blurred(_ rect: CGRect, sigma: CGFloat) -> (CGImage, CGRect)? {
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let key = RedactKey(blur: true, x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height), amount: Int(sigma * 4))
        if let cached = cached(key) { return (cached, r) }
        let ciRect = CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
        let out = CIImage(cgImage: image).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(sigma, 0.5)))
            .cropped(to: ciRect)
        guard let result = Self.ciContext.createCGImage(out, from: ciRect, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        store(result, for: key)
        return (result, r)
    }

    /// A cached patch, marked as just used.
    private func cached(_ key: RedactKey) -> CGImage? {
        guard let image = redactions[key] else { return nil }
        if let index = redactionUse.lastIndex(of: key) { redactionUse.remove(at: index) }
        redactionUse.append(key)
        return image
    }

    /// Keeps at most `redactionLimit` patches, dropping the least recently used one first.
    private func store(_ image: CGImage, for key: RedactKey) {
        if redactions[key] == nil, redactions.count >= Self.redactionLimit, !redactionUse.isEmpty {
            redactions[redactionUse.removeFirst()] = nil
        }
        redactionUse.removeAll { $0 == key }
        redactionUse.append(key)
        redactions[key] = image
    }

    var cachedRedactionCount: Int { redactions.count }

    // MARK: Thumbnail

    func thumbnail(maxPixels: CGFloat) -> NSImage {
        let scale = min(1, maxPixels / max(size.width, size.height))
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let ctx = makeContext(width: w, height: h, opaque: false) else { return NSImage(cgImage: image, size: .zero) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return NSImage(cgImage: image, size: .zero) }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }
}

// MARK: - Background images

/// Wallpaper and custom background images, decoded once at a sensible size.
@MainActor
enum BackgroundImages {
    private static var cache: [String: CGImage] = [:]

    static func image(for fill: BackgroundFill) -> CGImage? {
        switch fill {
        case .wallpaper: return wallpaper()
        case .image(let path): return file(path)
        default: return nil
        }
    }

    static func wallpaper() -> CGImage? {
        if let cached = cache["wallpaper"] { return cached }
        guard let screen = NSScreen.main, let url = WallpaperLoader.pictureURL(for: screen) else { return nil }
        let image = decode(url)
        if let image { cache["wallpaper"] = image }
        return image
    }

    static func file(_ path: String) -> CGImage? {
        if let cached = cache[path] { return cached }
        let image = decode(URL(fileURLWithPath: path))
        if let image { cache[path] = image }
        return image
    }

    static func forget(_ path: String) { cache[path] = nil }

    private static func decode(_ url: URL) -> CGImage? {
        Thumbnails.decodeImage(at: url, maxPixelSize: 3200)
    }
}
