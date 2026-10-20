import AppKit

// MARK: - Text layout

/// Measures and places text labels. The renderer, the inline editor and label creation all use it so they agree.
enum TextLayout {
    struct Result {
        /// Pill/outline box, or just the text bounds for plain text.
        var box: CGRect
        var textOrigin: CGPoint
        var textSize: CGSize
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

    /// Horizontal space between the backdrop's edge and the text; the vertical space is 0.62 of it.
    private static func padding(_ style: ToolStyle, font: NSFont) -> CGFloat {
        style.backdrop == .plain ? 0 : (font.pointSize * 0.42).rounded()
    }

    /// `origin` is the top-left of the label's box.
    static func layout(text: String, at origin: CGPoint, style: ToolStyle, unit: CGFloat) -> Result {
        let font = font(style, unit: unit)
        let probe = (text + "\u{200B}") as NSString
        var size = probe.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: [.font: font]).size
        size = CGSize(width: ceil(max(size.width, font.pointSize * 0.1)), height: ceil(size.height))
        let pad = padding(style, font: font)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 2 * pad, height: size.height + 2 * pad * 0.62)
        let textOrigin = CGPoint(x: box.minX + pad, y: box.minY + pad * 0.62)
        let radius = style.backdrop == .pill ? box.height / 2 : min(box.height * 0.28, font.pointSize * 0.5)
        return Result(box: box, textOrigin: textOrigin, textSize: size, radius: radius)
    }

    /// The box origin for a new label clicked at `p`: the text starts at the click, its first line centered on it.
    static func origin(clickedAt p: CGPoint, style: ToolStyle, unit: CGFloat) -> CGPoint {
        let font = font(style, unit: unit)
        let pad = padding(style, font: font)
        return CGPoint(x: p.x - pad, y: p.y - font.pointSize * 0.6 - pad * 0.62)
    }
}

// MARK: - Handles

enum Handle: Hashable {
    case tl, t, tr, r, br, b, bl, l
    case start, end, bend

    var isCorner: Bool { self == .tl || self == .tr || self == .br || self == .bl }

    private static let rectHandles: [Handle] = [.tl, .t, .tr, .r, .br, .b, .bl, .l]

    /// The eight handles around `r`, clockwise from the top left.
    static func points(for r: CGRect) -> [(Handle, CGPoint)] {
        rectHandles.map { ($0, $0.point(in: r)) }
    }

    /// The first handle within `radius` of `p`. `handles` and `p` must be in the same coordinates.
    static func hitHandle(_ handles: [(Handle, CGPoint)], at p: CGPoint, radius: CGFloat) -> Handle? {
        handles.first { hypot($0.1.x - p.x, $0.1.y - p.y) <= radius }?.0
    }

    /// Where this rect handle sits on `r`.
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .tl: CGPoint(x: r.minX, y: r.minY)
        case .t: CGPoint(x: r.midX, y: r.minY)
        case .tr: CGPoint(x: r.maxX, y: r.minY)
        case .r: CGPoint(x: r.maxX, y: r.midY)
        case .br: CGPoint(x: r.maxX, y: r.maxY)
        case .b: CGPoint(x: r.midX, y: r.maxY)
        case .bl: CGPoint(x: r.minX, y: r.maxY)
        case .l, .start, .end, .bend: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The rect handle across from this one: the point that stays put while this one is dragged.
    var opposite: Handle {
        switch self {
        case .tl: .br
        case .t: .b
        case .tr: .bl
        case .r: .l
        case .br: .tl
        case .b: .t
        case .bl: .tr
        case .l, .start, .end, .bend: .r
        }
    }

    /// `r` with this handle dragged to `p`. A corner may lock to `ratio`; an edge moves only its own side.
    func drag(_ r: CGRect, to p: CGPoint, ratio: CGFloat?) -> CGRect {
        let anchor = opposite.point(in: r)
        switch self {
        case .t, .b: return .dragRect(anchor: CGPoint(x: r.minX, y: anchor.y), to: CGPoint(x: r.maxX, y: p.y), ratio: nil)
        case .l, .r: return .dragRect(anchor: CGPoint(x: anchor.x, y: r.minY), to: CGPoint(x: p.x, y: r.maxY), ratio: nil)
        default: return .dragRect(anchor: anchor, to: p, ratio: ratio)
        }
    }

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
        case .start, .end, .bend: NSCursor.crosshair
        }
    }
}

extension CGRect {
    /// The rect between a fixed `anchor` and a dragged point `p`. With a `ratio` (width / height) the short side grows to match.
    static func dragRect(anchor: CGPoint, to p: CGPoint, ratio: CGFloat?) -> CGRect {
        var w = abs(p.x - anchor.x), h = abs(p.y - anchor.y)
        if let ratio {
            if w / max(h, 0.001) > ratio { h = w / ratio } else { w = h * ratio }
        }
        return CGRect(x: p.x >= anchor.x ? anchor.x : anchor.x - w, y: p.y >= anchor.y ? anchor.y : anchor.y - h, width: w, height: h)
    }
}

// MARK: - Annotation geometry

/// Everything that depends on an annotation's shape. Each operation is one switch over the five shapes;
/// the kind only contributes data from `ToolKind.traits`.
extension Annotation {
    /// Stroke width, diameter or thickness in points. 0 for kinds without a size.
    var strokeWidth: CGFloat {
        let sizes = kind.traits.sizes
        return sizes.isEmpty ? 0 : sizes[min(max(style.sizeIndex, 0), 2)]
    }

    /// A box drawn as an outline: it has a stroke you can grab, rather than an area.
    private var isOutlinedBox: Bool { !kind.traits.sizes.isEmpty && !style.filled }

    /// The counter's disc, centered on its point.
    func markerRect(_ center: CGPoint, unit: CGFloat) -> CGRect {
        let d = strokeWidth * unit
        return CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
    }

    /// Points along a segment: the straight line, or the arrow's curve. Empty for other shapes.
    func centerline(samples: Int = 32) -> [CGPoint] {
        guard case .segment(let p0, let p1, let bend) = shape else { return [] }
        guard style.curved else { return [p0, p1] }
        let c = Self.curveControl(p0, p1, bend: bend)
        return (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            let u = 1 - t
            return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                           y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
        }
    }

    private static func curveControl(_ p0: CGPoint, _ p1: CGPoint, bend: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return mid }
        return CGPoint(x: mid.x - dy / len * bend * len, y: mid.y + dx / len * bend * len)
    }

    /// Where the curvature handle sits.
    private static func bendHandle(_ p0: CGPoint, _ p1: CGPoint, bend: CGFloat) -> CGPoint {
        let c = curveControl(p0, p1, bend: bend)
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        return CGPoint(x: mid.x + (c.x - mid.x) / 2, y: mid.y + (c.y - mid.y) / 2)
    }

    /// Bounds used for selection chrome and marquee selection, in document pixels.
    func bounds(unit: CGFloat) -> CGRect {
        switch shape {
        case .segment:
            let w = strokeWidth * unit * 1.2
            return Self.boundingBox(centerline(samples: 12)).insetBy(dx: -w, dy: -w)
        case .box(let r):
            let w = isOutlinedBox ? strokeWidth * unit / 2 : 0
            return r.insetBy(dx: -w, dy: -w)
        case .stroke(let points):
            guard !points.isEmpty else { return .zero }
            let w = strokeWidth * unit / 2
            return Self.boundingBox(points).insetBy(dx: -w, dy: -w)
        case .marker(let center):
            return markerRect(center, unit: unit)
        case .label(let origin, let text):
            return TextLayout.layout(text: text, at: origin, style: style, unit: unit).box
        }
    }

    /// `tol` is in document pixels (the canvas converts from screen points).
    func hit(_ p: CGPoint, tol: CGFloat, unit: CGFloat) -> Bool {
        switch shape {
        case .segment:
            return Self.distance(from: p, toPolyline: centerline()) <= tol + strokeWidth * unit * 0.8
        case .box(let r):
            // Redactions and spotlights are areas.
            guard !kind.traits.sizes.isEmpty else { return r.insetBy(dx: -tol * 0.5, dy: -tol * 0.5).contains(p) }
            let reach = tol + strokeWidth * unit / 2
            if kind.traits.oval {
                let rx = r.width / 2, ry = r.height / 2
                guard rx > 0, ry > 0 else { return false }
                let nx = (p.x - r.midX) / (rx + reach), ny = (p.y - r.midY) / (ry + reach)
                if nx * nx + ny * ny > 1 { return false }
                if style.filled { return true }
                let ix = (p.x - r.midX) / max(rx - reach, 0.001), iy = (p.y - r.midY) / max(ry - reach, 0.001)
                return rx - reach <= 0 || ry - reach <= 0 || ix * ix + iy * iy >= 1
            }
            if style.filled { return r.insetBy(dx: -tol, dy: -tol).contains(p) }
            let outer = r.insetBy(dx: -reach, dy: -reach)
            let inner = r.insetBy(dx: reach, dy: reach)
            return outer.contains(p) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .stroke(let points):
            let reach = tol + strokeWidth * unit / 2
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= reach }
            return Self.distance(from: p, toPolyline: points) <= reach
        case .marker(let center):
            let r = markerRect(center, unit: unit)
            return hypot(p.x - r.midX, p.y - r.midY) <= r.width / 2 + tol * 0.5
        case .label(let origin, let text):
            return TextLayout.layout(text: text, at: origin, style: style, unit: unit).box.insetBy(dx: -tol * 0.5, dy: -tol * 0.5).contains(p)
        }
    }

    func handlePoints(unit: CGFloat) -> [(Handle, CGPoint)] {
        switch shape {
        case .segment(let p0, let p1, let bend):
            var result: [(Handle, CGPoint)] = [(.start, p0), (.end, p1)]
            if style.curved { result.append((.bend, Self.bendHandle(p0, p1, bend: bend))) }
            return result
        case .box(let r):
            return Handle.points(for: r)
        case .label(let origin, let text):
            let box = TextLayout.layout(text: text, at: origin, style: style, unit: unit).box
            return Handle.points(for: box).filter { $0.0.isCorner }
        case .stroke, .marker:
            return []
        }
    }

    /// Moves `handle` to `p`, starting from `original` so a drag never accumulates error.
    /// `constrain` (Shift) snaps segment ends to 45 degrees and keeps box corners square.
    mutating func apply(handle: Handle, to p: CGPoint, original o: Annotation, unit: CGFloat, constrain: Bool) {
        switch o.shape {
        case .segment(let p0, let p1, let bend):
            switch handle {
            case .start:
                shape = .segment(p0: constrain ? Self.snapAngle(from: p1, to: p) : p, p1: p1, bend: bend)
            case .end:
                shape = .segment(p0: p0, p1: constrain ? Self.snapAngle(from: p0, to: p) : p, bend: bend)
            case .bend:
                let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                let dx = p1.x - p0.x, dy = p1.y - p0.y
                let len = hypot(dx, dy)
                guard len > 0.001 else { return }
                let perp = CGPoint(x: -dy / len, y: dx / len)
                shape = .segment(p0: p0, p1: p1, bend: 2 * ((p.x - mid.x) * perp.x + (p.y - mid.y) * perp.y) / len)
            default:
                break
            }
        case .box(let r):
            shape = .box(handle.drag(r, to: p, ratio: constrain ? 1 : nil))
        case .label(let origin, let text):
            // Corners scale the font around the opposite corner.
            let box = TextLayout.layout(text: text, at: origin, style: o.style, unit: unit).box
            let anchor = handle.opposite.point(in: box), moving = handle.point(in: box)
            let oldDist = hypot(moving.x - anchor.x, moving.y - anchor.y)
            guard oldDist > 0 else { return }
            let scale = max(0.2, min(8, hypot(p.x - anchor.x, p.y - anchor.y) / oldDist))
            let newSize = max(8, min(400, o.style.fontSize * Double(scale)))
            let applied = CGFloat(newSize / o.style.fontSize)
            style.fontSize = newSize
            shape = .label(origin: CGPoint(x: anchor.x - (anchor.x - origin.x) * applied, y: anchor.y - (anchor.y - origin.y) * applied), text: text)
        case .stroke, .marker:
            break
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        switch shape {
        case .segment(let p0, let p1, let bend): shape = .segment(p0: moved(p0), p1: moved(p1), bend: bend)
        case .box(let r): shape = .box(r.offsetBy(dx: dx, dy: dy))
        case .stroke(let points): shape = .stroke(points.map(moved))
        case .marker(let center): shape = .marker(moved(center))
        case .label(let origin, let text): shape = .label(origin: moved(origin), text: text)
        }
    }

    /// Reshapes a new annotation as it is dragged out from `start` to `p`. `constrain` (Shift) snaps
    /// segments to 45 degrees, makes boxes square and freehand strokes straight. `minStep` is the shortest
    /// freehand segment kept, in document pixels.
    mutating func dragOut(from start: CGPoint, to p: CGPoint, constrain: Bool, minStep: CGFloat) {
        switch shape {
        case .segment(let p0, _, let bend):
            shape = .segment(p0: p0, p1: constrain ? Self.snapAngle(from: start, to: p) : p, bend: bend)
        case .box:
            shape = .box(.dragRect(anchor: start, to: p, ratio: constrain ? 1 : nil))
        case .stroke(var points):
            if constrain {
                points = [start, p]
            } else if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= minStep {
                points.append(p)
            }
            shape = .stroke(points)
        case .marker:
            shape = .marker(p)
        case .label:
            break
        }
    }

    /// True for an annotation not worth keeping once made: a click without a drag (`minLength` in document
    /// pixels), or a label left blank.
    func isTooSmall(minLength: CGFloat) -> Bool {
        switch shape {
        case .segment(let p0, let p1, _): hypot(p1.x - p0.x, p1.y - p0.y) < minLength
        case .box(let r): max(r.width, r.height) < minLength
        case .stroke, .marker: false
        case .label(_, let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Helpers

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
