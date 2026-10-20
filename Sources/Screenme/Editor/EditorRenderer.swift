import AppKit

/// Draws a document into a CGContext. The same code paints the live canvas and the exported file,
/// so what you see is what you save. The context must be y-down with its origin at the canvas top-left.
/// This is the one place that looks at an annotation's kind to decide how it is drawn.
@MainActor
enum EditorRenderer {
    /// - Parameters:
    ///   - layout: where the image sits, and the background around it if any. `state.background` is not read.
    ///   - baseScale: device pixels per context unit before any transform (the window's backing scale on screen, 1 for bitmaps). Needed because CoreGraphics shadows ignore the CTM.
    ///   - hideTextOf: the text annotation being edited inline: its backdrop is drawn, its glyphs are not.
    static func render(state: EditState, layout: Layout, source: ImageSource, unit: CGFloat, ctx: CGContext,
                       baseScale: CGFloat, hideTextOf: UUID? = nil) {
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        let content = layout.contentRect

        ctx.saveGState()
        ctx.clip(to: canvas)
        ctx.interpolationQuality = .high

        var radius: CGFloat = 0
        if let bg = layout.background {
            radius = min(CGFloat(bg.cornerRadius) * unit, min(content.width, content.height) / 2)
            drawBackground(bg.fill, in: canvas, ctx: ctx)
            if bg.shadow > 0.001 {
                drawShadow(of: content, radius: radius, strength: bg.shadow, unit: unit, ctx: ctx, baseScale: baseScale)
            }
        }

        // The image and everything that reads its pixels.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.translateBy(x: layout.docOffset.x, y: layout.docOffset.y)
        ctx.clip(to: layout.cropRect)

        if state.canvasFill.a > 0 {
            ctx.setFillColor(state.canvasFill.cgColor)
            ctx.fill(layout.cropRect)
        }
        drawBase(source, ctx: ctx)
        for a in state.annotations { drawRedaction(a, source: source, unit: unit, ctx: ctx) }
        drawSpotlights(state.annotations, dim: state.spotlightDim, crop: layout.cropRect, ctx: ctx)
        ctx.restoreGState()

        // Annotations may spill past the image onto the background. Without one the image fills the canvas.
        ctx.saveGState()
        ctx.translateBy(x: layout.docOffset.x, y: layout.docOffset.y)
        drawAnnotations(state.annotations, unit: unit, ctx: ctx, baseScale: baseScale, hideTextOf: hideTextOf)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    // MARK: Export

    /// Flattens the document to pixels. `opaque` fills transparency with white (for JPEG).
    static func flatten(state: EditState, source: ImageSource, opaque: Bool) -> CGImage? {
        let layout = state.exportLayout
        let scale = state.outputScale
        let w = Int((layout.canvasSize.width * scale).rounded())
        let h = Int((layout.canvasSize.height * scale).rounded())
        guard w > 0, h > 0, w * h < 480_000_000, let ctx = source.makeContext(width: w, height: h, opaque: opaque) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(w) / layout.canvasSize.width, y: CGFloat(h) / layout.canvasSize.height)
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: layout.canvasSize))
        }
        render(state: state, layout: layout, source: source, unit: source.unit, ctx: ctx, baseScale: 1)
        return ctx.makeImage()
    }

    // MARK: Pieces

    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func drawBase(_ source: ImageSource, ctx: CGContext) {
        let device = hypot(ctx.ctm.a, ctx.ctm.b)
        drawImage(source.level(forScale: device), in: source.bounds, ctx: ctx)
    }

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
    private static func drawShadow(of rect: CGRect, radius: CGFloat, strength: Double, unit: CGFloat, ctx: CGContext, baseScale: CGFloat) {
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

    /// Pixelate and blur replace the image's pixels under them; other kinds draw nothing here.
    private static func drawRedaction(_ a: Annotation, source: ImageSource, unit: CGFloat, ctx: CGContext) {
        guard case .box(let rect) = a.shape, rect.width >= 1, rect.height >= 1 else { return }
        switch a.kind {
        case .pixelate:
            let block = (5 + 34 * CGFloat(a.style.intensity)) * unit
            guard let (patch, r) = source.pixelated(rect, block: block) else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .none
            drawImage(patch, in: r, ctx: ctx)
            ctx.restoreGState()
        case .blur:
            let sigma = (3 + 26 * CGFloat(a.style.intensity)) * unit
            guard let (patch, r) = source.blurred(rect, sigma: sigma) else { return }
            drawImage(patch, in: r, ctx: ctx)
        default:
            break
        }
    }

    private static func drawSpotlights(_ annotations: [Annotation], dim: Double, crop: CGRect, ctx: CGContext) {
        let spots: [(CGRect, Bool)] = annotations.compactMap { a in
            guard a.kind == .spotlight, case .box(let r) = a.shape, r.width >= 1, r.height >= 1 else { return nil }
            return (r, a.style.ellipseSpot)
        }
        guard !spots.isEmpty else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(dim)))
        ctx.fill(crop.insetBy(dx: -4, dy: -4))
        ctx.setBlendMode(.clear)
        for (rect, ellipse) in spots {
            if ellipse { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Annotations

    private static func drawAnnotations(_ annotations: [Annotation], unit: CGFloat, ctx: CGContext, baseScale: CGFloat, hideTextOf: UUID?) {
        var number = 0
        for a in annotations {
            if a.kind == .counter { number += 1 }
            draw(a, number: number, unit: unit, ctx: ctx, baseScale: baseScale, hideText: a.id == hideTextOf)
        }
    }

    /// One annotation above the image. Redactions and spotlights are part of the image layer and draw nothing here.
    static func draw(_ a: Annotation, number: Int, unit: CGFloat, ctx: CGContext, baseScale: CGFloat, hideText: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.style.color.cgColor
        let w = a.strokeWidth * unit
        let opacity = CGFloat(a.style.opacity)

        switch (a.kind, a.shape) {
        case (.pixelate, _), (.blur, _), (.spotlight, _):
            return
        case (.highlighter, .stroke(let points)):
            guard !points.isEmpty else { return }
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(opacity)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(points))
            ctx.strokePath()
            return
        default:
            break
        }

        let k = hypot(ctx.ctm.a, ctx.ctm.b) / baseScale
        let layered = a.style.shadow || opacity < 0.999
        if a.style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -2.4 * unit * k), blur: 6 * unit * k, color: CGColor(gray: 0, alpha: 0.4))
        }
        if layered {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if layered { ctx.endTransparencyLayer() } }

        switch (a.kind, a.shape) {
        case (.arrow, .segment(_, let p1, _)):
            drawArrow(a, tip: p1, unit: unit, ctx: ctx)
        case (.line, .segment(let p0, let p1, _)):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            if a.style.dashed { ctx.setLineDash(phase: 0, lengths: [w * 2, w * 2]) }
            ctx.move(to: p0)
            ctx.addLine(to: p1)
            ctx.strokePath()
        case (.rectangle, .box(let rect)), (.ellipse, .box(let rect)):
            drawBoxShape(a, rect: rect, w: w, unit: unit, ctx: ctx)
        case (.pen, .stroke(let points)):
            guard !points.isEmpty else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if a.style.dashed { ctx.setLineDash(phase: 0, lengths: [w * 2, w * 2.4]) }
            ctx.addPath(smoothPath(points))
            ctx.strokePath()
        case (.counter, .marker(let center)):
            drawCounter(a, center: center, number: number, unit: unit, ctx: ctx)
        case (.text, .label(let origin, let text)):
            drawText(a, text: text, at: origin, unit: unit, ctx: ctx, hideText: hideText)
        default:
            break
        }
    }

    private static func drawBoxShape(_ a: Annotation, rect: CGRect, w: CGFloat, unit: CGFloat, ctx: CGContext) {
        let color = a.style.color.cgColor
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let r = a.style.filled ? rect : rect.insetBy(dx: w / 2, dy: w / 2)
        guard r.width > 0, r.height > 0 else { return }
        let path: CGPath
        if a.kind == .ellipse {
            path = CGPath(ellipseIn: r, transform: nil)
        } else {
            let radius = a.style.rounded ? min(min(r.width, r.height) / 2, max(6 * unit, min(r.width, r.height) * 0.18)) : 0
            path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        ctx.addPath(path)
        if a.style.filled {
            ctx.setFillColor(color)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.setLineJoin(.round)
            if a.style.dashed { ctx.setLineDash(phase: 0, lengths: [w * 2, w * 2]) }
            ctx.strokePath()
        }
    }

    private static func drawCounter(_ a: Annotation, center: CGPoint, number: Int, unit: CGFloat, ctx: CGContext) {
        let r = a.markerRect(center, unit: unit)
        ctx.setFillColor(a.style.color.cgColor)
        ctx.fillEllipse(in: r)
        let ring = max(1.5 * unit, r.width * 0.06)
        ctx.setStrokeColor(a.style.color.contrast.with(alpha: 0.9).cgColor)
        ctx.setLineWidth(ring)
        ctx.strokeEllipse(in: r.insetBy(dx: ring / 2, dy: ring / 2))

        let text = "\(max(number, 1))" as NSString
        let fontSize = r.width * (text.length > 2 ? 0.4 : text.length > 1 ? 0.5 : 0.58)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: a.style.color.contrast.nsColor,
        ]
        let size = text.size(withAttributes: attrs)
        withFlippedGraphics(ctx) {
            text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private static func drawText(_ a: Annotation, text: String, at origin: CGPoint, unit: CGFloat, ctx: CGContext, hideText: Bool) {
        let layout = TextLayout.layout(text: text, at: origin, style: a.style, unit: unit)
        switch a.style.backdrop {
        case .pill:
            ctx.setFillColor(a.style.color.cgColor)
            ctx.addPath(CGPath(roundedRect: layout.box, cornerWidth: layout.radius, cornerHeight: layout.radius, transform: nil))
            ctx.fillPath()
        case .outline:
            let lw = max(2 * unit, a.style.fontSize * unit * 0.085)
            let box = layout.box.insetBy(dx: lw / 2, dy: lw / 2)
            ctx.setStrokeColor(a.style.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: layout.radius, cornerHeight: layout.radius, transform: nil))
            ctx.strokePath()
        case .plain:
            break
        }
        guard !hideText, !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: TextLayout.attributes(a.style, unit: unit))
        withFlippedGraphics(ctx) {
            string.draw(with: CGRect(origin: layout.textOrigin, size: CGSize(width: layout.textSize.width + 8, height: layout.textSize.height + 4)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    /// Runs AppKit text drawing against a y-down CGContext.
    private static func withFlippedGraphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Paths

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        switch pts.count {
        case 1:
            path.addLine(to: first)
        case 2:
            path.addLine(to: pts[1])
        default:
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts[pts.count - 1])
        }
        return path
    }

    // MARK: Arrow

    /// A tapered arrow: thin at the tail, full width at the head, with a triangular head at `tip`.
    static func arrowPath(_ a: Annotation, tip: CGPoint, unit: CGFloat) -> CGPath {
        let w = a.strokeWidth * unit
        let samples = 48
        let raw = a.centerline(samples: samples)
        let line: [CGPoint] = raw.count > 2 ? raw : (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            return CGPoint(x: raw[0].x + (raw[1].x - raw[0].x) * t, y: raw[0].y + (raw[1].y - raw[0].y) * t)
        }
        var cumulative: [CGFloat] = [0]
        for i in 1..<line.count { cumulative.append(cumulative[i - 1] + hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y)) }
        let total = cumulative.last ?? 0
        let path = CGMutablePath()
        guard total > 0.5 else { return path }

        let headLen = min(w * 3.8 + 4 * unit, total * 0.6)
        let headHalf = headLen * 0.42
        let shaftEnd = total - headLen

        func point(at s: CGFloat) -> (CGPoint, CGPoint) {
            var i = 1
            while i < cumulative.count - 1 && cumulative[i] < s { i += 1 }
            let span = max(cumulative[i] - cumulative[i - 1], 0.0001)
            let t = max(0, min(1, (s - cumulative[i - 1]) / span))
            let p = CGPoint(x: line[i - 1].x + (line[i].x - line[i - 1].x) * t, y: line[i - 1].y + (line[i].y - line[i - 1].y) * t)
            let dx = line[i].x - line[i - 1].x, dy = line[i].y - line[i - 1].y
            let len = max(hypot(dx, dy), 0.0001)
            return (p, CGPoint(x: -dy / len, y: dx / len))
        }

        let tailHalf = max(w * 0.12, 0.6 * unit)
        let neckHalf = w * 0.5
        let steps = 40
        var left: [CGPoint] = [], right: [CGPoint] = []
        let shaftReach = min(total, shaftEnd + headLen * 0.12)
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let s = shaftReach * f
            let (p, n) = point(at: s + 0.001)
            let hw = tailHalf + (neckHalf - tailHalf) * min(s / max(shaftEnd, 0.001), 1)
            left.append(CGPoint(x: p.x + n.x * hw, y: p.y + n.y * hw))
            right.append(CGPoint(x: p.x - n.x * hw, y: p.y - n.y * hw))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()

        let (base, _) = point(at: shaftEnd)
        let dx = tip.x - base.x, dy = tip.y - base.y
        let len = max(hypot(dx, dy), 0.0001)
        let nx = -dy / len, ny = dx / len
        path.move(to: tip)
        // Same winding as the shaft, so the overlap stays filled.
        path.addLine(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf))
        path.addLine(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        path.closeSubpath()
        return path
    }

    private static func drawArrow(_ a: Annotation, tip: CGPoint, unit: CGFloat, ctx: CGContext) {
        let path = arrowPath(a, tip: tip, unit: unit)
        guard !path.isEmpty else { return }
        let w = a.strokeWidth * unit
        if a.style.outline {
            let outlineColor = a.style.color.isLight ? RGBA(0.1, 0.1, 0.12) : RGBA.white
            ctx.addPath(path)
            ctx.setStrokeColor(outlineColor.cgColor)
            ctx.setLineWidth(max(2 * unit, w * 0.62))
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        ctx.addPath(path)
        ctx.setFillColor(a.style.color.cgColor)
        ctx.fillPath()
    }
}
