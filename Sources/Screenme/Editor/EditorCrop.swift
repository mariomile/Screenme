import AppKit

// MARK: - Session

enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, fourThree, sixteenNine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

/// The crop being set up. Nothing changes in the document until it is applied.
struct CropSession: Equatable {
    /// The rect that Apply Crop keeps, in image pixels.
    var rect: CGRect
    var aspect = CropAspect.free
}

// MARK: - Math

enum CropMath {
    static func handlePoints(_ r: CGRect) -> [(Handle, CGPoint)] {
        [(.tl, CGPoint(x: r.minX, y: r.minY)), (.t, CGPoint(x: r.midX, y: r.minY)),
         (.tr, CGPoint(x: r.maxX, y: r.minY)), (.r, CGPoint(x: r.maxX, y: r.midY)),
         (.br, CGPoint(x: r.maxX, y: r.maxY)), (.b, CGPoint(x: r.midX, y: r.maxY)),
         (.bl, CGPoint(x: r.minX, y: r.maxY)), (.l, CGPoint(x: r.minX, y: r.midY))]
    }

    /// Resizes `rect` by dragging `handle` to `p`, inside `limit`, optionally locked to `ratio` (width / height).
    static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint, ratio: CGFloat?, limit: CGRect, minSize: CGFloat) -> CGRect {
        let p = CGPoint(x: min(max(point.x, limit.minX), limit.maxX), y: min(max(point.y, limit.minY), limit.maxY))
        var l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY
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
        guard let ratio else {
            var out = CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
            if out.width < minSize { out.size.width = minSize; if l > r { out.origin.x = r } }
            if out.height < minSize { out.size.height = minSize; if t > b { out.origin.y = b } }
            return out.intersection(limit).isNull ? rect : out
        }

        if handle.isCorner {
            let anchor = CGPoint(x: (handle == .tl || handle == .bl) ? rect.maxX : rect.minX,
                                 y: (handle == .tl || handle == .tr) ? rect.maxY : rect.minY)
            let sx: CGFloat = p.x >= anchor.x ? 1 : -1
            let sy: CGFloat = p.y >= anchor.y ? 1 : -1
            let availW = sx > 0 ? limit.maxX - anchor.x : anchor.x - limit.minX
            let availH = sy > 0 ? limit.maxY - anchor.y : anchor.y - limit.minY
            var w = max(abs(p.x - anchor.x), minSize)
            var h = w / ratio
            if h < abs(p.y - anchor.y) { h = abs(p.y - anchor.y); w = h * ratio }
            let scale = min(1, availW / max(w, 1), availH / max(h, 1))
            w *= scale; h *= scale
            return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
        }

        // Edge handle: the dragged edge sets one dimension, the other follows around the center.
        let horizontal = handle == .l || handle == .r
        if horizontal {
            let fixedX = handle == .r ? rect.minX : rect.maxX
            var w = max(abs(p.x - fixedX), minSize)
            var h = w / ratio
            let maxH = 2 * min(rect.midY - limit.minY, limit.maxY - rect.midY)
            if h > maxH { h = maxH; w = h * ratio }
            let x = handle == .r ? fixedX : fixedX - w
            return CGRect(x: x, y: rect.midY - h / 2, width: w, height: h)
        } else {
            let fixedY = handle == .b ? rect.minY : rect.maxY
            var h = max(abs(p.y - fixedY), minSize)
            var w = h * ratio
            let maxW = 2 * min(rect.midX - limit.minX, limit.maxX - rect.midX)
            if w > maxW { w = maxW; h = w / ratio }
            let y = handle == .b ? fixedY : fixedY - h
            return CGRect(x: rect.midX - w / 2, y: y, width: w, height: h)
        }
    }

    /// A new rect dragged out from `start` to `point`, inside `limit`, optionally locked to `ratio`.
    static func newRect(from start: CGPoint, to point: CGPoint, ratio: CGFloat?, limit: CGRect) -> CGRect {
        let p = CGPoint(x: min(max(point.x, limit.minX), limit.maxX), y: min(max(point.y, limit.minY), limit.maxY))
        let sx: CGFloat = p.x >= start.x ? 1 : -1
        let sy: CGFloat = p.y >= start.y ? 1 : -1
        var w = abs(p.x - start.x), h = abs(p.y - start.y)
        if let ratio, w > 0 || h > 0 {
            if w / max(h, 0.001) > ratio { h = w / ratio } else { w = h * ratio }
            let availW = sx > 0 ? limit.maxX - start.x : start.x - limit.minX
            let availH = sy > 0 ? limit.maxY - start.y : start.y - limit.minY
            let k = min(1, availW / max(w, 0.001), availH / max(h, 0.001))
            w *= k; h *= k
        }
        return CGRect(x: sx > 0 ? start.x : start.x - w, y: sy > 0 ? start.y : start.y - h, width: w, height: h)
    }

    /// The biggest rect of `ratio` that fits inside `rect`, centered.
    static func fit(_ rect: CGRect, ratio: CGFloat) -> CGRect {
        var w = rect.width, h = rect.width / ratio
        if h > rect.height { h = rect.height; w = h * ratio }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Interaction

/// The crop tool's mouse handling, cursor and overlay. The canvas hands its events here while the mode is `.crop`.
/// `toView` converts document pixels to canvas view points.
@MainActor
struct CropInteraction {
    private enum Drag {
        case resize(Handle, original: CGRect)
        case move(start: CGPoint, original: CGRect)
        case new(start: CGPoint)
    }

    /// View points around a handle that still grab it.
    private static let handleReach: CGFloat = 12
    /// Smallest crop in image pixels.
    private static let minSize: CGFloat = 8

    private let drag: Drag

    private static func handle(at view: CGPoint, of rect: CGRect, toView: (CGPoint) -> CGPoint) -> Handle? {
        for (handle, p) in CropMath.handlePoints(rect) {
            let v = toView(p)
            if hypot(v.x - view.x, v.y - view.y) <= handleReach { return handle }
        }
        return nil
    }

    /// A mouse-down at `doc` (`view` in canvas points): grabs a handle, moves the rect, or starts a new one.
    init(mouseDownAt doc: CGPoint, view: CGPoint, controller: EditorController, toView: (CGPoint) -> CGPoint) {
        let rect = controller.mode.crop?.rect ?? controller.cropLimit
        if let handle = Self.handle(at: view, of: rect, toView: toView) {
            drag = .resize(handle, original: rect)
        } else if rect.contains(doc) {
            drag = .move(start: doc, original: rect)
        } else {
            drag = .new(start: doc)
            let limit = controller.cropLimit
            controller.updateCrop { $0.rect = CropMath.newRect(from: doc, to: doc, ratio: $0.aspect.ratio, limit: limit) }
        }
    }

    func dragged(to doc: CGPoint, controller: EditorController) {
        let limit = controller.cropLimit
        controller.updateCrop { session in
            switch drag {
            case .resize(let handle, let original):
                session.rect = CropMath.resize(original, handle: handle, to: doc, ratio: session.aspect.ratio, limit: limit, minSize: Self.minSize)
            case .move(let start, let original):
                var r = original.offsetBy(dx: doc.x - start.x, dy: doc.y - start.y)
                r.origin.x = min(max(r.minX, limit.minX), limit.maxX - r.width)
                r.origin.y = min(max(r.minY, limit.minY), limit.maxY - r.height)
                session.rect = r
            case .new(let start):
                session.rect = CropMath.newRect(from: start, to: doc, ratio: session.aspect.ratio, limit: limit)
            }
        }
    }

    /// A click without a drag leaves a sliver: go back to the whole image instead.
    func ended(controller: EditorController) {
        guard case .new = drag, let r = controller.mode.crop?.rect, r.width < Self.minSize || r.height < Self.minSize else { return }
        controller.resetCropSelection()
    }

    static func cursor(at view: CGPoint, doc: CGPoint, session: CropSession, toView: (CGPoint) -> CGPoint) -> NSCursor {
        if let handle = handle(at: view, of: session.rect, toView: toView) { return handle.resizeCursor }
        return session.rect.contains(doc) ? .openHand : .crosshair
    }

    /// Dims everything outside the crop and draws its frame, thirds, handles and size.
    static func drawOverlay(_ ctx: CGContext, session: CropSession, canvasRect: CGRect, viewBounds: CGRect, toView: (CGPoint) -> CGPoint) {
        let pending = session.rect
        let a = toView(pending.origin), b = toView(CGPoint(x: pending.maxX, y: pending.maxY))
        let r = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let dim = CGMutablePath()
        dim.addRect(canvasRect)
        dim.addRect(r)
        ctx.saveGState()
        ctx.addPath(dim)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))

        // Rule of thirds.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        for i in 1...2 {
            let f = CGFloat(i) / 3
            ctx.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        ctx.strokePath()

        // Corner brackets and edge bars.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        let arm: CGFloat = min(18, min(r.width, r.height) / 3)
        for (h, p) in CropMath.handlePoints(pending).map({ ($0.0, toView($0.1)) }) {
            switch h {
            case .tl: ctx.move(to: CGPoint(x: p.x, y: p.y + arm)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            case .tr: ctx.move(to: CGPoint(x: p.x - arm, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm))
            case .br: ctx.move(to: CGPoint(x: p.x, y: p.y - arm)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x - arm, y: p.y))
            case .bl: ctx.move(to: CGPoint(x: p.x + arm, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y - arm))
            case .t, .b: ctx.move(to: CGPoint(x: p.x - arm / 2, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + arm / 2, y: p.y))
            case .l, .r: ctx.move(to: CGPoint(x: p.x, y: p.y - arm / 2)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm / 2))
            default: break
            }
        }
        ctx.strokePath()
        ctx.setLineCap(.butt)

        // Size label.
        let label = "\(Int(pending.width.rounded())) × \(Int(pending.height.rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: r.midX - size.width / 2 - 8, y: r.maxY + 8, width: size.width + 16, height: size.height + 6)
        let pillRect = pill.maxY > viewBounds.maxY - 4 ? pill.offsetBy(dx: 0, dy: -(pill.height + 16)) : pill
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillRect.height / 2, cornerHeight: pillRect.height / 2, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: pillRect.minX + 8, y: pillRect.minY + 3), withAttributes: attrs)
    }
}
