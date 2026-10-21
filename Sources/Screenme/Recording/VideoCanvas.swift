import AppKit
import CoreImage

extension Pref {
    /// The video editor's last background, as JSON `BackgroundSettings`. Empty: off.
    static let videoCanvas = PrefKey(name: "videoCanvas", defaultValue: Data())
}

/// The background around an edited video. It reuses the image editor's background: the same `BackgroundSettings`,
/// fills, `Layout` math and drawing, so a video and a screenshot wrapped alike look alike.
enum VideoCanvas {
    /// The aspect ratios the video editor offers.
    static let aspects: [AspectPreset] = [.auto, .sixteenNine, .nineSixteen, .square, .fourThree]
    static let paddingRange = 0.0...20.0
    static let cornerRange = 0.0...40.0

    static var saved: BackgroundSettings {
        get {
            var settings = (try? JSONDecoder().decode(BackgroundSettings.self, from: Prefs[Pref.videoCanvas])) ?? BackgroundSettings()
            settings.padding = min(max(settings.padding, paddingRange.lowerBound), paddingRange.upperBound)
            if !aspects.contains(settings.aspect) { settings.aspect = .auto }
            settings.alignment = .center
            return settings
        }
        set { Prefs[Pref.videoCanvas] = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Where a video of `videoSize` pixels sits on the canvas, y-down, in video pixels. The video is centered.
    static func layout(videoSize: CGSize, settings: BackgroundSettings) -> Layout {
        var settings = settings
        settings.alignment = .center
        return Layout.make(crop: CGRect(origin: .zero, size: videoSize), background: settings)
    }

    /// `layout` scaled to an output of `renderSize` pixels: where the video lands, in output pixels with the origin
    /// bottom-left as Core Image wants it.
    static func contentRect(_ layout: Layout, renderSize: CGSize) -> CGRect {
        let sx = renderSize.width / layout.canvasSize.width, sy = renderSize.height / layout.canvasSize.height
        let content = layout.contentRect
        return CGRect(x: content.minX * sx, y: (layout.canvasSize.height - content.maxY) * sy,
                      width: content.width * sx, height: content.height * sy)
    }

    /// The canvas painted once per edit: the fill, and the video's shadow, drawn by the image editor's renderer.
    /// `unit` is output pixels per point, which corner radius and shadow are measured in.
    @MainActor
    static func backgroundImage(_ settings: BackgroundSettings, renderSize: CGSize, contentRect: CGRect, unit: CGFloat) -> CIImage? {
        let width = Int(renderSize.width), height = Int(renderSize.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The editor draws y-down from the top-left.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let canvas = CGRect(origin: .zero, size: renderSize)
        let content = CGRect(x: contentRect.minX, y: renderSize.height - contentRect.maxY, width: contentRect.width, height: contentRect.height)
        EditorRenderer.drawBackground(settings.fill, in: canvas, ctx: ctx)
        if settings.shadow > 0.001 {
            EditorRenderer.drawShadow(of: content, radius: cornerRadius(settings, contentRect: contentRect, unit: unit),
                                      strength: settings.shadow, unit: unit, ctx: ctx, baseScale: 1)
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    static func cornerRadius(_ settings: BackgroundSettings, contentRect: CGRect, unit: CGFloat) -> CGFloat {
        min(CGFloat(settings.cornerRadius) * unit, min(contentRect.width, contentRect.height) / 2)
    }

    /// White inside the video's rounded rectangle, nothing outside. Nil for square corners.
    static func mask(contentRect: CGRect, radius: CGFloat) -> CIImage? {
        guard radius > 0.5 else { return nil }
        return CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: contentRect),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])?.outputImage
    }
}
