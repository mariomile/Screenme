import AppKit

/// The editing surface. It owns zoom and pan, turns mouse input into annotation changes, draws the
/// selection chrome and crop overlay, and hosts the inline text editor.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    /// Strong: the controller only holds the canvas weakly, and AppKit may call into the view while the window tears down.
    private let controller: EditorController

    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var fitMode = true
    private var lastCanvasSize = CGSize.zero

    var spaceDown = false {
        didSet { if spaceDown != oldValue { refreshCursor() } }
    }

    private enum Gesture {
        case none
        case pan(startPan: CGPoint, start: CGPoint)
        case create(id: UUID, start: CGPoint, kind: ToolKind)
        case move(last: CGPoint)
        case resize(id: UUID, handle: Handle, original: Annotation)
        case marquee(start: CGPoint, additive: Bool, base: Set<UUID>)
        case cropResize(handle: Handle, original: CGRect)
        case cropMove(start: CGPoint, original: CGRect)
        case cropNew(start: CGPoint)
    }
    private var gesture = Gesture.none
    private var marquee: CGRect?

    private var textView: NSTextView?
    private var editingID: UUID?

    private var unit: CGFloat { controller.unit }
    private var minZoom: CGFloat { 0.04 / unit }
    private var maxZoom: CGFloat { 8 / unit }

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.canvas = self
        lastCanvasSize = controller.layout.canvasSize
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {}

    // MARK: Geometry

    private var canvasOrigin: CGPoint {
        let size = lastCanvasSize
        return CGPoint(x: bounds.midX - size.width * zoom / 2 + pan.x, y: bounds.midY - size.height * zoom / 2 + pan.y)
    }

    private func toCanvas(_ p: CGPoint) -> CGPoint {
        let o = canvasOrigin
        return CGPoint(x: (p.x - o.x) / zoom, y: (p.y - o.y) / zoom)
    }

    private func toDoc(_ p: CGPoint) -> CGPoint { controller.layout.canvasToDoc(toCanvas(p)) }

    private func toView(_ doc: CGPoint) -> CGPoint {
        let c = controller.layout.docToCanvas(doc)
        let o = canvasOrigin
        return CGPoint(x: o.x + c.x * zoom, y: o.y + c.y * zoom)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let a = toView(rect.origin), b = toView(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private var tolerance: CGFloat { 6 / zoom }

    // MARK: Zoom and pan

    func documentChanged(refit: Bool = false) {
        let size = controller.layout.canvasSize
        if refit { fitMode = true }
        if size != lastCanvasSize || refit {
            lastCanvasSize = size
            if fitMode { applyFit() } else { clampPan() }
        }
        updateTextViewFrame()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitMode { applyFit() } else { clampPan() }
        updateTextViewFrame()
    }

    private func fitZoomValue() -> CGFloat {
        let size = lastCanvasSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 / unit }
        let margin: CGFloat = 32
        let z = min((bounds.width - 2 * margin) / size.width, (bounds.height - 2 * margin) / size.height)
        return max(minZoom, min(z, 1 / unit))
    }

    private func applyFit() {
        zoom = fitZoomValue()
        pan = .zero
        publishZoom()
        needsDisplay = true
    }

    private func publishZoom() {
        let percent = Int((zoom * unit * 100).rounded())
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller.zoomPercent != percent else { return }
            self.controller.zoomPercent = percent
        }
    }

    private func clampPan() {
        let w = lastCanvasSize.width * zoom, h = lastCanvasSize.height * zoom
        let limitX = max(0, (w - bounds.width) / 2 + 80)
        let limitY = max(0, (h - bounds.height) / 2 + 80)
        pan.x = min(max(pan.x, -limitX), limitX)
        pan.y = min(max(pan.y, -limitY), limitY)
    }

    private func setZoom(_ value: CGFloat, anchor: CGPoint) {
        let target = min(max(value, minZoom), maxZoom)
        let canvasPoint = toCanvas(anchor)
        fitMode = false
        zoom = target
        let size = lastCanvasSize
        pan = CGPoint(x: anchor.x - canvasPoint.x * zoom - (bounds.midX - size.width * zoom / 2),
                      y: anchor.y - canvasPoint.y * zoom - (bounds.midY - size.height * zoom / 2))
        clampPan()
        publishZoom()
        updateTextViewFrame()
        needsDisplay = true
    }

    func zoomStep(_ factor: CGFloat) { setZoom(zoom * factor, anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }

    func zoomToFit() {
        fitMode = true
        applyFit()
        updateTextViewFrame()
    }

    func zoomToActual() { setZoom(1 / unit, anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(zoom - 1 / unit) < 0.001 { zoomToFit() } else { setZoom(1 / unit, anchor: convert(event.locationInWindow, from: nil)) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.05
            setZoom(zoom * exp(amount), anchor: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        pan.x += event.scrollingDeltaX * k
        pan.y += event.scrollingDeltaY * k
        clampPan()
        updateTextViewFrame()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.125, alpha: 1) : NSColor(white: 0.87, alpha: 1)).setFill()
        bounds.fill()

        let layout = controller.layout
        let origin = canvasOrigin
        let canvasRect = CGRect(origin: origin, size: CGSize(width: layout.canvasSize.width * zoom, height: layout.canvasSize.height * zoom))

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22, color: CGColor(gray: 0, alpha: dark ? 0.7 : 0.28))
        ctx.setFillColor(CGColor(gray: dark ? 0.2 : 1, alpha: 1))
        ctx.fill(canvasRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: canvasRect)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: zoom, y: zoom)
        EditorRenderer.render(state: controller.state, layout: layout, source: controller.source, unit: unit, ctx: ctx,
                              baseScale: window?.backingScaleFactor ?? 2, hideTextOf: editingID)
        ctx.restoreGState()

        if controller.isCropping, let pending = controller.cropPending {
            drawCropOverlay(ctx, pending: pending, canvasRect: canvasRect)
        } else {
            drawSelection(ctx)
        }
        if let marquee {
            let r = toView(marquee)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawSelection(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor
        let single = controller.selection.count == 1
        for a in controller.selectedAnnotations {
            if !a.kind.isLineLike {
                let r = toView(a.bounds(unit: unit)).insetBy(dx: -2, dy: -2)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.25)
                if a.kind.isFreehand { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
                ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
            } else {
                // A thin highlight along the line shows what is selected.
                let pts = a.centerline().map { toView($0) }
                if let first = pts.first {
                    ctx.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
                    ctx.setLineWidth(1)
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    ctx.move(to: first)
                    for p in pts.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            }
            if single {
                for (_, p) in a.handlePoints(unit: unit) { drawHandle(ctx, at: toView(p), accent: accent) }
            }
        }
    }

    private func drawHandle(_ ctx: CGContext, at p: CGPoint, accent: NSColor) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
        ctx.fillEllipse(in: r.insetBy(dx: -1.5, dy: -1.5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.75)
        ctx.strokeEllipse(in: r.insetBy(dx: 0.9, dy: 0.9))
    }

    private func drawCropOverlay(_ ctx: CGContext, pending: CGRect, canvasRect: CGRect) {
        let r = toView(pending)
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
        let pillRect = pill.maxY > bounds.maxY - 4 ? pill.offsetBy(dx: 0, dy: -(pill.height + 16)) : pill
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillRect.height / 2, cornerHeight: pillRect.height / 2, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: pillRect.minX + 8, y: pillRect.minY + 3), withAttributes: attrs)
    }

    // MARK: Hit testing

    private func annotation(withID id: UUID) -> Annotation? {
        controller.state.annotations.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        controller.state.annotations.firstIndex { $0.id == id }
    }

    private func topmostAnnotation(at doc: CGPoint) -> Annotation? {
        controller.state.annotations.last { $0.hit(doc, tol: tolerance, unit: unit) }
    }

    private func handleHit(at view: CGPoint) -> (Annotation, Handle)? {
        guard controller.selection.count == 1, let a = controller.selectedAnnotations.first else { return nil }
        for (handle, p) in a.handlePoints(unit: unit) {
            let v = toView(p)
            if hypot(v.x - view.x, v.y - view.y) <= 9 { return (a, handle) }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        if spaceDown {
            gesture = .pan(startPan: pan, start: vp)
            NSCursor.closedHand.set()
            return
        }
        let dp = toDoc(vp)
        let shift = event.modifierFlags.contains(.shift)

        if controller.tool == .crop {
            cropMouseDown(vp, dp)
            return
        }

        if let (a, handle) = handleHit(at: vp) {
            controller.beginChange()
            gesture = .resize(id: a.id, handle: handle, original: a)
            return
        }

        let hit = topmostAnnotation(at: dp)
        if event.clickCount == 2, let hit, hit.kind == .text {
            controller.select([hit.id])
            beginTextEditing(hit.id)
            return
        }

        switch controller.tool {
        case .select:
            if let hit {
                if shift {
                    var ids = controller.selection
                    if ids.contains(hit.id) { ids.remove(hit.id) } else { ids.insert(hit.id) }
                    controller.select(ids)
                } else if !controller.selection.contains(hit.id) {
                    controller.select([hit.id])
                }
                controller.beginChange()
                gesture = .move(last: dp)
            } else {
                if !shift { controller.select([]) }
                gesture = .marquee(start: dp, additive: shift, base: controller.selection)
            }
        case .text:
            if let hit, hit.kind == .text {
                controller.select([hit.id])
                beginTextEditing(hit.id)
            } else {
                createText(at: dp)
            }
        case .crop:
            break
        default:
            if let hit, controller.selection.contains(hit.id) {
                controller.beginChange()
                gesture = .move(last: dp)
            } else {
                startCreate(controller.tool, at: dp)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        let dp = toDoc(vp)
        let shift = event.modifierFlags.contains(.shift)

        switch gesture {
        case .none:
            break

        case .pan(let startPan, let start):
            pan = CGPoint(x: startPan.x + vp.x - start.x, y: startPan.y + vp.y - start.y)
            clampPan()
            updateTextViewFrame()
            needsDisplay = true

        case .create(let id, let start, let kind):
            guard let i = index(of: id) else { return }
            var a = controller.state.annotations[i]
            switch kind {
            case .arrow, .line:
                a.p1 = shift ? Annotation.snapAngle(from: start, to: dp) : dp
            case .pen, .highlighter:
                if shift {
                    a.points = [start, dp]
                } else if let last = a.points.last, hypot(dp.x - last.x, dp.y - last.y) * zoom >= 1.5 {
                    a.points.append(dp)
                }
            case .counter:
                a.p0 = dp
            default:
                var end = dp
                if shift {
                    let side = max(abs(dp.x - start.x), abs(dp.y - start.y))
                    end = CGPoint(x: start.x + (dp.x >= start.x ? side : -side), y: start.y + (dp.y >= start.y ? side : -side))
                }
                a.rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            }
            controller.state.annotations[i] = a

        case .move(let last):
            let dx = dp.x - last.x, dy = dp.y - last.y
            let ids = controller.selection
            var s = controller.state
            for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                s.annotations[i].translate(dx: dx, dy: dy)
            }
            controller.state = s
            gesture = .move(last: dp)

        case .resize(let id, let handle, let original):
            guard let i = index(of: id) else { return }
            var a = controller.state.annotations[i]
            a.apply(handle: handle, to: dp, original: original, unit: unit, constrain: shift)
            controller.state.annotations[i] = a

        case .marquee(let start, let additive, let base):
            let r = CGRect(x: min(start.x, dp.x), y: min(start.y, dp.y), width: abs(dp.x - start.x), height: abs(dp.y - start.y))
            marquee = r
            var ids = additive ? base : []
            for a in controller.state.annotations where a.bounds(unit: unit).intersects(r) { ids.insert(a.id) }
            controller.select(ids)

        case .cropResize(let handle, let original):
            controller.cropPending = CropMath.resize(original, handle: handle, to: dp, ratio: controller.cropAspect.ratio,
                                                     limit: controller.cropLimit, minSize: 8)
            needsDisplay = true

        case .cropMove(let start, let original):
            let limit = controller.cropLimit
            var r = original.offsetBy(dx: dp.x - start.x, dy: dp.y - start.y)
            r.origin.x = min(max(r.minX, limit.minX), limit.maxX - r.width)
            r.origin.y = min(max(r.minY, limit.minY), limit.maxY - r.height)
            controller.cropPending = r
            needsDisplay = true

        case .cropNew(let start):
            controller.cropPending = newCropRect(from: start, to: dp)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = .none
        switch finished {
        case .create(let id, _, let kind):
            finishCreate(id: id, kind: kind)
        case .move, .resize:
            controller.endChange()
        case .marquee:
            marquee = nil
            needsDisplay = true
        case .pan:
            refreshCursor()
        case .cropNew:
            if let r = controller.cropPending, r.width < 8 || r.height < 8 { controller.resetCropSelection() }
        default:
            break
        }
    }

    private func startCreate(_ kind: ToolKind, at p: CGPoint) {
        var a = Annotation(kind: kind, style: controller.styles[kind] ?? .defaults(for: kind))
        switch kind {
        case .arrow, .line: a.p0 = p; a.p1 = p
        case .pen, .highlighter: a.points = [p]
        case .counter: a.p0 = p
        default: a.rect = CGRect(origin: p, size: .zero)
        }
        controller.beginChange()
        controller.state.annotations.append(a)
        gesture = .create(id: a.id, start: p, kind: kind)
    }

    private func finishCreate(id: UUID, kind: ToolKind) {
        guard let a = annotation(withID: id) else { controller.endChange(); return }
        var tiny = false
        switch kind {
        case .arrow, .line: tiny = hypot(a.p1.x - a.p0.x, a.p1.y - a.p0.y) * zoom < 5
        case .counter, .pen, .highlighter: tiny = false
        default: tiny = max(a.rect.width, a.rect.height) * zoom < 5
        }
        if tiny {
            controller.state.annotations.removeAll { $0.id == id }
        } else {
            controller.select([id])
        }
        controller.endChange()
    }

    // MARK: Crop

    private func cropMouseDown(_ vp: CGPoint, _ dp: CGPoint) {
        guard let r = controller.cropPending else { return }
        for (handle, p) in CropMath.handlePoints(r) {
            let v = toView(p)
            if hypot(v.x - vp.x, v.y - vp.y) <= 12 {
                gesture = .cropResize(handle: handle, original: r)
                return
            }
        }
        if r.contains(dp) {
            gesture = .cropMove(start: dp, original: r)
        } else {
            gesture = .cropNew(start: dp)
            controller.cropPending = newCropRect(from: dp, to: dp)
        }
    }

    private func newCropRect(from start: CGPoint, to point: CGPoint) -> CGRect {
        let limit = controller.cropLimit
        let p = CGPoint(x: min(max(point.x, limit.minX), limit.maxX), y: min(max(point.y, limit.minY), limit.maxY))
        let sx: CGFloat = p.x >= start.x ? 1 : -1
        let sy: CGFloat = p.y >= start.y ? 1 : -1
        var w = abs(p.x - start.x), h = abs(p.y - start.y)
        if let ratio = controller.cropAspect.ratio, w > 0 || h > 0 {
            if w / max(h, 0.001) > ratio { h = w / ratio } else { w = h * ratio }
            let availW = sx > 0 ? limit.maxX - start.x : start.x - limit.minX
            let availH = sy > 0 ? limit.maxY - start.y : start.y - limit.minY
            let k = min(1, availW / max(w, 0.001), availH / max(h, 0.001))
            w *= k; h *= k
        }
        return CGRect(x: sx > 0 ? start.x : start.x - w, y: sy > 0 ? start.y : start.y - h, width: w, height: h)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    func refreshCursor() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateCursor(at vp: CGPoint) {
        guard bounds.contains(vp) else { return }
        if case .pan = gesture { NSCursor.closedHand.set(); return }
        if spaceDown { NSCursor.openHand.set(); return }
        let dp = toDoc(vp)

        if controller.tool == .crop, let r = controller.cropPending {
            for (handle, p) in CropMath.handlePoints(r) {
                let v = toView(p)
                if hypot(v.x - vp.x, v.y - vp.y) <= 12 { resizeCursor(for: handle).set(); return }
            }
            (r.contains(dp) ? NSCursor.openHand : NSCursor.crosshair).set()
            return
        }
        if let (_, handle) = handleHit(at: vp) {
            resizeCursor(for: handle).set()
            return
        }
        switch controller.tool {
        case .select:
            (topmostAnnotation(at: dp) != nil ? NSCursor.openHand : NSCursor.arrow).set()
        case .text:
            NSCursor.iBeam.set()
        default:
            if let hit = topmostAnnotation(at: dp), controller.selection.contains(hit.id) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
        }
    }

    private func resizeCursor(for handle: Handle) -> NSCursor {
        switch handle {
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

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let vp = convert(event.locationInWindow, from: nil)
        guard controller.tool != .crop, let hit = topmostAnnotation(at: toDoc(vp)) else { return nil }
        if !controller.selection.contains(hit.id) { controller.select([hit.id]) }
        let menu = NSMenu()
        if hit.kind == .text {
            menu.addItem(withTitle: "Edit Text", action: #selector(menuEditText), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Duplicate", action: #selector(menuDuplicate), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring to Front", action: #selector(menuFront), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Bring Forward", action: #selector(menuForward), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send Backward", action: #selector(menuBackward), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send to Back", action: #selector(menuBack), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(menuDelete), keyEquivalent: "").target = self
        return menu
    }

    @objc private func menuEditText() { if let id = controller.selection.first { beginTextEditing(id) } }
    @objc private func menuDuplicate() { controller.duplicateSelection() }
    @objc private func menuFront() { controller.arrange(.front) }
    @objc private func menuForward() { controller.arrange(.forward) }
    @objc private func menuBackward() { controller.arrange(.backward) }
    @objc private func menuBack() { controller.arrange(.back) }
    @objc private func menuDelete() { controller.deleteSelection() }

    // MARK: Inline text

    private func createText(at p: CGPoint) {
        var a = Annotation(kind: .text, style: controller.styles[.text] ?? .defaults(for: .text))
        let pad = a.style.backdrop == .plain ? 0 : a.style.fontSize * unit * 0.42
        a.rect.origin = CGPoint(x: p.x - pad, y: p.y - a.style.fontSize * unit * 0.6 - pad * 0.62)
        controller.beginChange()
        controller.state.annotations.append(a)
        controller.select([a.id])
        beginTextEditing(a.id, alreadyBegan: true)
    }

    func beginTextEditing(_ id: UUID, alreadyBegan: Bool = false) {
        finishTextEditing()
        guard let a = annotation(withID: id), a.kind == .text else { return }
        if !alreadyBegan { controller.beginChange() }
        let tv = NSTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 1_000_000, height: 1_000_000)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = a.text
        tv.delegate = self
        textView = tv
        editingID = id
        controller.isEditingText = true
        addSubview(tv)
        updateTextViewFrame()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        needsDisplay = true
    }

    func finishTextEditing() {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        controller.isEditingText = false
        tv.delegate = nil
        let text = tv.string
        let wasFirstResponder = window?.firstResponder === tv
        tv.removeFromSuperview()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.state.annotations.removeAll { $0.id == id }
            controller.select(controller.selection.subtracting([id]))
        } else if let i = index(of: id) {
            controller.state.annotations[i].text = text
        }
        controller.endChange()
        if wasFirstResponder { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func updateTextViewFrame() {
        guard let tv = textView, let id = editingID, let a = annotation(withID: id) else { return }
        let layout = TextLayout.layout(a, unit: unit)
        let origin = toView(layout.textOrigin)
        tv.font = NSFont.systemFont(ofSize: a.style.fontSize * unit * zoom, weight: a.style.weight.weight)
        let color = TextLayout.textColor(a.style).nsColor
        tv.textColor = color
        tv.insertionPointColor = color
        tv.frame = CGRect(x: origin.x, y: origin.y, width: layout.textSize.width * zoom + 14, height: layout.textSize.height * zoom + 2)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID, let i = index(of: id) else { return }
        controller.state.annotations[i].text = tv.string
    }

    func textDidEndEditing(_ notification: Notification) {
        finishTextEditing()
    }
}
