import AppKit

/// Drawing the background wrap: its fill and the image's drop shadow. `EditorRenderer.render` calls these
/// when the layout has a background.
extension EditorRenderer {
    static func drawBackground(_ fill: BackgroundFill, in rect: CGRect, ctx: CGContext) {
        switch fill {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let id):
            drawGradient(GradientSpec.spec(id), in: rect, ctx: ctx)
        case .wallpaper, .image:
            guard let image = BackgroundImages.image(for: fill) else {
                drawGradient(GradientSpec.spec("sunset"), in: rect, ctx: ctx)
                return
            }
            let s = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
            ctx.saveGState()
            ctx.clip(to: rect)
            drawImage(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), ctx: ctx)
            ctx.restoreGState()
        }
    }

    static func drawGradient(_ spec: GradientSpec, in rect: CGRect, ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = spec.colors.map(\.cgColor) as CFArray
        let stops = (0..<spec.colors.count).map { CGFloat($0) / CGFloat(max(spec.colors.count - 1, 1)) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops) else { return }
        let a = spec.angle * .pi / 180
        let dx = cos(a), dy = sin(a)
        let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        let start = CGPoint(x: rect.midX - dx * half, y: rect.midY - dy * half)
        let end = CGPoint(x: rect.midX + dx * half, y: rect.midY + dy * half)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Only the shadow is painted: the content rect itself is clipped out so transparent screenshots stay clean.
    static func drawShadow(of rect: CGRect, radius: CGFloat, strength: Double, unit: CGFloat, ctx: CGContext, baseScale: CGFloat) {
        let k = hypot(ctx.ctm.a, ctx.ctm.b) / baseScale
        let s = CGFloat(strength)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let clip = CGMutablePath()
        clip.addRect(rect.insetBy(dx: -rect.width * 2, dy: -rect.height * 2))
        clip.addPath(shape)
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -(10 + 22 * s) * unit * k),
                      blur: (18 + 46 * s) * unit * k,
                      color: CGColor(gray: 0, alpha: 0.2 + 0.5 * s))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
