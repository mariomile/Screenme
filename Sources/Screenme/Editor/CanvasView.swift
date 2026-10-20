import AppKit
import Carbon.HIToolbox

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
        case create(EditorController.Checkpoint, id: UUID, start: CGPoint)
        case move(EditorController.Checkpoint, last: CGPoint)
        case resize(EditorController.Checkpoint, id: UUID, handle: Handle, original: Annotation)
        case marquee(start: CGPoint, additive: Bool, base: Set<UUID>)
        case crop(CropInteraction)
    }
    private var gesture = Gesture.none
    private var marquee: CGRect?

    private var textView: InlineTextView?
    private var editingID: UUID?
    /// The document before the inline edit began, including before a new label was added.
    private var textCheckpoint: EditorController.Checkpoint?

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

    /// The canvas starts with the keyboard focus, so tool keys work as soon as the window opens.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    /// Plain keys, while the canvas has focus. A focused control or the inline text editor keeps its own
    /// keys; Cmd shortcuts are the window's.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command) else { return }
        let step: CGFloat = mods.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Space where mods.isDisjoint(with: [.control, .option]):
            spaceDown = true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if controller.mode.crop != nil { controller.applyCrop() } else { controller.save() }
        case kVK_Escape:
            if controller.mode.crop != nil { controller.cancelCrop() } else if !controller.selection.isEmpty { controller.select([]) }
        case kVK_Delete, kVK_ForwardDelete:
            controller.deleteSelection()
        case kVK_LeftArrow: controller.nudge(dx: -step, dy: 0)
        case kVK_RightArrow: controller.nudge(dx: step, dy: 0)
        case kVK_DownArrow: controller.nudge(dx: 0, dy: step)
        case kVK_UpArrow: controller.nudge(dx: 0, dy: -step)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if mods.isEmpty || mods == .shift, let choice = ToolChoice.all.first(where: { $0.key == key }) {
                controller.choose(choice)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { spaceDown = false }
    }

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

        if let session = controller.mode.crop {
            CropInteraction.drawOverlay(ctx, session: session, canvasRect: canvasRect, viewBounds: bounds, toView: toView)
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
            if case .segment = a.shape {
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
            } else {
                let r = toView(a.bounds(unit: unit)).insetBy(dx: -2, dy: -2)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.25)
                if case .stroke = a.shape { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
                ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
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
        let handles = a.handlePoints(unit: unit).map { ($0.0, toView($0.1)) }
        return Handle.hitHandle(handles, at: view, radius: 9).map { (a, $0) }
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

        if controller.mode.crop != nil {
            gesture = .crop(CropInteraction(mouseDownAt: dp, view: vp, controller: controller, toView: toView))
            return
        }

        if let (a, handle) = handleHit(at: vp) {
            gesture = .resize(controller.checkpoint(), id: a.id, handle: handle, original: a)
            return
        }

        let hit = topmostAnnotation(at: dp)
        if event.clickCount == 2, let hit, case .label = hit.shape {
            controller.select([hit.id])
            beginTextEditing(hit.id)
            return
        }

        switch controller.mode {
        case .select:
            if let hit {
                if shift {
                    var ids = controller.selection
                    if ids.contains(hit.id) { ids.remove(hit.id) } else { ids.insert(hit.id) }
                    controller.select(ids)
                } else if !controller.selection.contains(hit.id) {
                    controller.select([hit.id])
                }
                gesture = .move(controller.checkpoint(), last: dp)
            } else {
                if !shift { controller.select([]) }
                gesture = .marquee(start: dp, additive: shift, base: controller.selection)
            }
        case .draw(.text):
            if let hit, case .label = hit.shape {
                controller.select([hit.id])
                beginTextEditing(hit.id)
            } else {
                createText(at: dp)
            }
        case .draw(let kind):
            if let hit, controller.selection.contains(hit.id) {
                gesture = .move(controller.checkpoint(), last: dp)
            } else {
                startCreate(kind, at: dp)
            }
        case .crop:
            break
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

        case .create(_, let id, let start):
            let minStep = 1.5 / zoom
            modify(id) { $0.dragOut(from: start, to: dp, constrain: shift, minStep: minStep) }

        case .move(let before, let last):
            let dx = dp.x - last.x, dy = dp.y - last.y
            let ids = controller.selection
            controller.update { s in
                for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                    s.annotations[i].translate(dx: dx, dy: dy)
                }
            }
            gesture = .move(before, last: dp)

        case .resize(_, let id, let handle, let original):
            let unit = unit
            modify(id) { $0.apply(handle: handle, to: dp, original: original, unit: unit, constrain: shift) }

        case .marquee(let start, let additive, let base):
            let r = CGRect(x: min(start.x, dp.x), y: min(start.y, dp.y), width: abs(dp.x - start.x), height: abs(dp.y - start.y))
            marquee = r
            var ids = additive ? base : []
            for a in controller.state.annotations where a.bounds(unit: unit).intersects(r) { ids.insert(a.id) }
            controller.select(ids)

        case .crop(let crop):
            crop.dragged(to: dp, controller: controller)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = .none
        switch finished {
        case .create(let before, let id, _):
            finishCreate(id: id, since: before)
        case .move(let before, _), .resize(let before, _, _, _):
            controller.commit(since: before)
        case .marquee:
            marquee = nil
            needsDisplay = true
        case .pan:
            refreshCursor()
        case .crop(let crop):
            crop.ended(controller: controller)
        default:
            break
        }
    }

    private func startCreate(_ kind: ToolKind, at p: CGPoint) {
        let a = Annotation(kind: kind, style: controller.styles[kind] ?? kind.traits.style, at: p)
        let before = controller.checkpoint()
        controller.update { $0.annotations.append(a) }
        gesture = .create(before, id: a.id, start: p)
    }

    private func finishCreate(id: UUID, since before: EditorController.Checkpoint) {
        if let a = annotation(withID: id), a.isTooSmall(minLength: 5 / zoom) {
            controller.update { $0.annotations.removeAll { $0.id == id } }
        } else if annotation(withID: id) != nil {
            controller.select([id])
        }
        controller.commit(since: before)
    }

    /// Changes one annotation through the controller, if it still exists.
    private func modify(_ id: UUID, _ change: (inout Annotation) -> Void) {
        controller.update { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { change(&s.annotations[i]) }
        }
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

        if let session = controller.mode.crop {
            CropInteraction.cursor(at: vp, doc: dp, session: session, toView: toView).set()
            return
        }
        if let (_, handle) = handleHit(at: vp) {
            handle.resizeCursor.set()
            return
        }
        switch controller.mode {
        case .select:
            (topmostAnnotation(at: dp) != nil ? NSCursor.openHand : NSCursor.arrow).set()
        case .draw(.text):
            NSCursor.iBeam.set()
        case .draw, .crop:
            if let hit = topmostAnnotation(at: dp), controller.selection.contains(hit.id) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let vp = convert(event.locationInWindow, from: nil)
        guard controller.mode.crop == nil, let hit = topmostAnnotation(at: toDoc(vp)) else { return nil }
        if !controller.selection.contains(hit.id) { controller.select([hit.id]) }
        let menu = NSMenu()
        if case .label = hit.shape {
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
        let style = controller.styles[.text] ?? ToolKind.text.traits.style
        let a = Annotation(kind: .text, style: style, at: TextLayout.origin(clickedAt: p, style: style, unit: unit))
        let before = controller.checkpoint()
        controller.update { $0.annotations.append(a) }
        controller.select([a.id])
        beginTextEditing(a.id, since: before)
    }

    /// `before` is the document before the edit; a new label passes the one from before it was added.
    func beginTextEditing(_ id: UUID, since before: EditorController.Checkpoint? = nil) {
        finishTextEditing()
        guard let a = annotation(withID: id), case .label(_, let text) = a.shape else { return }
        textCheckpoint = before ?? controller.checkpoint()
        let tv = InlineTextView(frame: .zero)
        tv.onFinish = { [weak self] in self?.finishTextEditing() }
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
        tv.string = text
        tv.delegate = self
        textView = tv
        editingID = id
        addSubview(tv)
        updateTextViewFrame()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        needsDisplay = true
    }

    func finishTextEditing() {
        guard let tv = textView, let id = editingID, let before = textCheckpoint else { return }
        textView = nil
        editingID = nil
        textCheckpoint = nil
        tv.delegate = nil
        let text = tv.string
        let wasFirstResponder = window?.firstResponder === tv
        tv.removeFromSuperview()
        setText(text, of: id)
        if let a = annotation(withID: id), a.isTooSmall(minLength: 0) {
            controller.update { $0.annotations.removeAll { $0.id == id } }
            controller.select(controller.selection.subtracting([id]))
        }
        controller.commit(since: before)
        if wasFirstResponder { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func updateTextViewFrame() {
        guard let tv = textView, let id = editingID, let a = annotation(withID: id), case .label(let labelOrigin, let text) = a.shape else { return }
        let layout = TextLayout.layout(text: text, at: labelOrigin, style: a.style, unit: unit)
        let origin = toView(layout.textOrigin)
        tv.font = NSFont.systemFont(ofSize: a.style.fontSize * unit * zoom, weight: a.style.weight.weight)
        let color = TextLayout.textColor(a.style).nsColor
        tv.textColor = color
        tv.insertionPointColor = color
        tv.frame = CGRect(x: origin.x, y: origin.y, width: layout.textSize.width * zoom + 14, height: layout.textSize.height * zoom + 2)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID else { return }
        setText(tv.string, of: id)
    }

    private func setText(_ text: String, of id: UUID) {
        modify(id) { a in
            if case .label(let origin, _) = a.shape { a.shape = .label(origin: origin, text: text) }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        finishTextEditing()
    }
}

/// The inline label editor. Escape or Cmd-Return finishes the edit.
private final class InlineTextView: NSTextView {
    var onFinish: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if code == kVK_Escape || (mods == .command && (code == kVK_Return || code == kVK_ANSI_KeypadEnter)) {
            onFinish()
            return
        }
        super.keyDown(with: event)
    }
}
