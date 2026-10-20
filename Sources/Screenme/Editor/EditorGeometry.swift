import AppKit

// MARK: - Text layout

/// Measures text annotations. The renderer and the inline editor both use this so they agree.
enum TextLayout {
    struct Result {
        /// Pill/outline box, or just the text bounds for plain text.
        var box: CGRect
        var textOrigin: CGPoint
        var textSize: CGSize
        var padding: CGFloat
        var radius: CGFloat
    }

    static func font(_ style: ToolStyle, unit: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * unit, weight: style.weight.weight)
    }

    static func textColor(_ style: ToolStyle) -> RGBA {
        style.backdrop == .pill ? style.color.contrast : style.color
    }

    static func attributes(_ style: ToolStyle, unit: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(style, unit: unit), .foregroundColor: textColor(style).nsColor]
    }

    static func layout(_ a: Annotation, unit: CGFloat) -> Result {
        let font = font(a.style, unit: unit)
        let probe = (a.text + "\u{200B}") as NSString
        var size = probe.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: [.font: font]).size
        size = CGSize(width: ceil(max(size.width, font.pointSize * 0.1)), height: ceil(size.height))
        let pad = a.style.backdrop == .plain ? 0 : (font.pointSize * 0.42).rounded()
        let box = CGRect(x: a.rect.minX, y: a.rect.minY, width: size.width + 2 * pad, height: size.height + 2 * pad * 0.62)
        let origin = CGPoint(x: box.minX + pad, y: box.minY + pad * 0.62)
        let radius = a.style.backdrop == .pill ? box.height / 2 : min(box.height * 0.28, font.pointSize * 0.5)
        return Result(box: box, textOrigin: origin, textSize: size, padding: pad, radius: radius)
    }
}

// MARK: - Handles

enum Handle: Hashable {
    case tl, t, tr, r, br, b, bl, l
    case start, end, bend

    var isCorner: Bool { self == .tl || self == .tr || self == .br || self == .bl }

    var resizeCursor: NSCursor {
        switch self {
        case .tl: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .tr: NSCursor.frameResize(position: .topRight, directions: .all)
        case .bl: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .br: NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .t: NSCursor.frameResize(position: .top, directions: .all)
        case .b: NSCursor.frameResize(position: .bottom, directions: .all)
        case .l: NSCursor.frameResize(position: .left, directions: .all)
        case .r: NSCursor.frameResize(position: .right, directions: .all)
        default: NSCursor.crosshair
        }
    }
}

// MARK: - Annotation geometry

extension Annotation {
    var strokeWidth: CGFloat { style.points(for: kind) }

    /// Counters are centered on `p0`.
    func counterRect(unit: CGFloat) -> CGRect {
        let d = style.points(for: .counter) * unit
        return CGRect(x: p0.x - d / 2, y: p0.y - d / 2, width: d, height: d)
    }

    func curveControl() -> CGPoint {
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return mid }
        return CGPoint(x: mid.x - dy / len * bend * len, y: mid.y + dx / len * bend * len)
    }

    var isCurved: Bool { kind == .arrow && style.curved }

    /// Points along the arrow or line.
    func centerline(samples: Int = 32) -> [CGPoint] {
        guard isCurved else { return [p0, p1] }
        let c = curveControl()
        return (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            let u = 1 - t
            return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                           y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
        }
    }

    /// The point the curvature handle sits on.
    func bendHandle() -> CGPoint {
        let c = curveControl()
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        return CGPoint(x: mid.x + (c.x - mid.x) / 2, y: mid.y + (c.y - mid.y) / 2)
    }

    /// Bounds used for selection chrome and marquee selection, in document pixels.
    func bounds(unit: CGFloat) -> CGRect {
        switch kind {
        case .arrow, .line:
            var pts = centerline(samples: 12)
            if pts.count == 2 { pts = [p0, p1] }
            return Self.boundingBox(pts).insetBy(dx: -strokeWidth * unit * 1.2, dy: -strokeWidth * unit * 1.2)
        case .pen, .highlighter:
            guard !points.isEmpty else { return .zero }
            let w = strokeWidth * unit / 2
            return Self.boundingBox(points).insetBy(dx: -w, dy: -w)
        case .counter:
            return counterRect(unit: unit)
        case .text:
            return TextLayout.layout(self, unit: unit).box
        case .rectangle, .ellipse:
            let w = style.filled ? 0 : strokeWidth * unit / 2
            return rect.insetBy(dx: -w, dy: -w)
        default:
            return rect
        }
    }

    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return pts.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .infinity }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(from: p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    /// `tol` is in document pixels (the canvas converts from screen points).
    func hit(_ p: CGPoint, tol: CGFloat, unit: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line:
            return Self.distance(from: p, toPolyline: centerline()) <= tol + strokeWidth * unit * 0.8
        case .pen, .highlighter:
            let reach = tol + strokeWidth * unit / 2
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= reach }
            return Self.distance(from: p, toPolyline: points) <= reach
        case .counter:
            let r = counterRect(unit: unit)
            return hypot(p.x - r.midX, p.y - r.midY) <= r.width / 2 + tol * 0.5
        case .text:
            return TextLayout.layout(self, unit: unit).box.insetBy(dx: -tol * 0.5, dy: -tol * 0.5).contains(p)
        case .rectangle:
            if style.filled { return rect.insetBy(dx: -tol, dy: -tol).contains(p) }
            let reach = tol + strokeWidth * unit / 2
            let outer = rect.insetBy(dx: -reach, dy: -reach)
            let inner = rect.insetBy(dx: reach, dy: reach)
            return outer.contains(p) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .ellipse:
            let reach = tol + strokeWidth * unit / 2
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let nx = (p.x - rect.midX) / (rx + reach), ny = (p.y - rect.midY) / (ry + reach)
            if nx * nx + ny * ny > 1 { return false }
            if style.filled { return true }
            let ix = (p.x - rect.midX) / max(rx - reach, 0.001), iy = (p.y - rect.midY) / max(ry - reach, 0.001)
            return rx - reach <= 0 || ry - reach <= 0 || ix * ix + iy * iy >= 1
        case .pixelate, .blur, .spotlight:
            return rect.insetBy(dx: -tol * 0.5, dy: -tol * 0.5).contains(p)
        }
    }

    // MARK: Handles

    func handlePoints(unit: CGFloat) -> [(Handle, CGPoint)] {
        switch kind {
        case .arrow:
            var result: [(Handle, CGPoint)] = [(.start, p0), (.end, p1)]
            if isCurved { result.append((.bend, bendHandle())) }
            return result
        case .line:
            return [(.start, p0), (.end, p1)]
        case .rectangle, .ellipse, .pixelate, .blur, .spotlight:
            let r = rect
            return [(.tl, CGPoint(x: r.minX, y: r.minY)), (.t, CGPoint(x: r.midX, y: r.minY)),
                    (.tr, CGPoint(x: r.maxX, y: r.minY)), (.r, CGPoint(x: r.maxX, y: r.midY)),
                    (.br, CGPoint(x: r.maxX, y: r.maxY)), (.b, CGPoint(x: r.midX, y: r.maxY)),
                    (.bl, CGPoint(x: r.minX, y: r.maxY)), (.l, CGPoint(x: r.minX, y: r.midY))]
        case .text:
            let r = TextLayout.layout(self, unit: unit).box
            return [(.tl, CGPoint(x: r.minX, y: r.minY)), (.tr, CGPoint(x: r.maxX, y: r.minY)),
                    (.br, CGPoint(x: r.maxX, y: r.maxY)), (.bl, CGPoint(x: r.minX, y: r.maxY))]
        default:
            return []
        }
    }

    /// Moves `handle` to `p`, starting from `original` so a drag never accumulates error.
    mutating func apply(handle: Handle, to p: CGPoint, original o: Annotation, unit: CGFloat, constrain: Bool) {
        switch kind {
        case .arrow, .line:
            switch handle {
            case .start: p0 = p
            case .end: p1 = p
            case .bend:
                let mid = CGPoint(x: (o.p0.x + o.p1.x) / 2, y: (o.p0.y + o.p1.y) / 2)
                let dx = o.p1.x - o.p0.x, dy = o.p1.y - o.p0.y
                let len = hypot(dx, dy)
                guard len > 0.001 else { return }
                let perp = CGPoint(x: -dy / len, y: dx / len)
                bend = 2 * ((p.x - mid.x) * perp.x + (p.y - mid.y) * perp.y) / len
            default: break
            }
            if constrain, handle == .start || handle == .end {
                let anchor = handle == .start ? p1 : p0
                let moved = Self.snapAngle(from: anchor, to: p)
                if handle == .start { p0 = moved } else { p1 = moved }
            }
        case .text:
            let layout = TextLayout.layout(o, unit: unit).box
            let anchor: CGPoint
            let moving: CGPoint
            switch handle {
            case .tl: anchor = CGPoint(x: layout.maxX, y: layout.maxY); moving = CGPoint(x: layout.minX, y: layout.minY)
            case .tr: anchor = CGPoint(x: layout.minX, y: layout.maxY); moving = CGPoint(x: layout.maxX, y: layout.minY)
            case .br: anchor = CGPoint(x: layout.minX, y: layout.minY); moving = CGPoint(x: layout.maxX, y: layout.maxY)
            default: anchor = CGPoint(x: layout.maxX, y: layout.minY); moving = CGPoint(x: layout.minX, y: layout.maxY)
            }
            let oldDist = hypot(moving.x - anchor.x, moving.y - anchor.y)
            guard oldDist > 0 else { return }
            let scale = max(0.2, min(8, hypot(p.x - anchor.x, p.y - anchor.y) / oldDist))
            let newSize = max(8, min(400, o.style.fontSize * Double(scale)))
            let applied = CGFloat(newSize / o.style.fontSize)
            style.fontSize = newSize
            rect.origin = CGPoint(x: anchor.x - (anchor.x - o.rect.minX) * applied,
                                  y: anchor.y - (anchor.y - o.rect.minY) * applied)
        default:
            var l = o.rect.minX, r = o.rect.maxX, t = o.rect.minY, b = o.rect.maxY
            switch handle {
            case .tl: l = p.x; t = p.y
            case .t: t = p.y
            case .tr: r = p.x; t = p.y
            case .r: r = p.x
            case .br: r = p.x; b = p.y
            case .b: b = p.y
            case .bl: l = p.x; b = p.y
            case .l: l = p.x
            default: break
            }
            if constrain, handle.isCorner {
                let side = max(abs(r - l), abs(b - t))
                switch handle {
                case .tl: l = r - side; t = b - side
                case .tr: r = l + side; t = b - side
                case .br: r = l + side; b = t + side
                default: l = r - side; b = t + side
                }
            }
            rect = CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
        }
    }

    /// Snaps the direction from `a` to `p` to the nearest 45 degrees.
    static func snapAngle(from a: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - a.x, dy = p.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }
}

