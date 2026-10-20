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
    private static func clamp(_ p: CGPoint, to limit: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, limit.minX), limit.maxX), y: min(max(p.y, limit.minY), limit.maxY))
    }

    /// `CGRect.dragRect` locked to `ratio`, then scaled toward `anchor` until it fits inside `limit`.
    private static func ratioRect(anchor: CGPoint, to p: CGPoint, ratio: CGFloat, limit: CGRect) -> CGRect {
        let r = CGRect.dragRect(anchor: anchor, to: p, ratio: ratio)
        let availW = p.x >= anchor.x ? limit.maxX - anchor.x : anchor.x - limit.minX
        let availH = p.y >= anchor.y ? limit.maxY - anchor.y : anchor.y - limit.minY
        let k = min(1, availW / max(r.width, 0.001), availH / max(r.height, 0.001))
        let w = r.width * k, h = r.height * k
        return CGRect(x: p.x >= anchor.x ? anchor.x : anchor.x - w, y: p.y >= anchor.y ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// Resizes `rect` by dragging `handle` to `p`, inside `limit`, optionally locked to `ratio` (width / height).
    static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint, ratio: CGFloat?, limit: CGRect, minSize: CGFloat) -> CGRect {
        let p = clamp(point, to: limit)
        guard let ratio else {
            var out = handle.drag(rect, to: p, ratio: nil)
            out.size.width = max(out.width, minSize)
            out.size.height = max(out.height, minSize)
            return out.intersection(limit).isNull ? rect : out
        }

        if handle.isCorner {
            let anchor = handle.opposite.point(in: rect)
            var q = p
            if abs(q.x - anchor.x) < minSize { q.x = anchor.x + (p.x >= anchor.x ? minSize : -minSize) }
            return ratioRect(anchor: anchor, to: q, ratio: ratio, limit: limit)
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
        let p = clamp(point, to: limit)
        guard let ratio else { return .dragRect(anchor: start, to: p, ratio: nil) }
        return ratioRect(anchor: start, to: p, ratio: ratio, limit: limit)
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

    private static func handle(at view: CGPoint, of rect: CGRect, viewport: Viewport) -> Handle? {
        Handle.hitHandle(Handle.points(for: rect).map { ($0.0, viewport.toView($0.1)) }, at: view, radius: handleReach)
    }

    /// A mouse-down at `doc` (`view` in canvas points): grabs a handle, moves the rect, or starts a new one.
    init(mouseDownAt doc: CGPoint, view: CGPoint, controller: EditorController, viewport: Viewport) {
        let rect = controller.mode.crop?.rect ?? controller.cropLimit
        if let handle = Self.handle(at: view, of: rect, viewport: viewport) {
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

    static func cursor(at view: CGPoint, doc: CGPoint, session: CropSession, viewport: Viewport) -> NSCursor {
        if let handle = handle(at: view, of: session.rect, viewport: viewport) { return handle.resizeCursor }
        return session.rect.contains(doc) ? .openHand : .crosshair
    }

    /// Dims everything outside the crop and draws its frame, thirds, handles and size.
    static func drawOverlay(_ ctx: CGContext, session: CropSession, viewport: Viewport, viewBounds: CGRect) {
        let pending = session.rect
        let r = viewport.toView(pending)
        let dim = CGMutablePath()
        dim.addRect(viewport.canvasRect)
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
        for (h, p) in Handle.points(for: pending).map({ ($0.0, viewport.toView($0.1)) }) {
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
