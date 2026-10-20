import AppKit
import Carbon.HIToolbox

/// The editing surface. It turns mouse and plain-key input into document changes, draws the document,
/// the selection chrome and the crop overlay, and hosts the inline text editor.
@MainActor
final class CanvasView: NSView {
    /// Strong: the controller only holds the canvas weakly, and AppKit may call into the view while the window tears down.
    private let controller: EditorController

    private var viewport: Viewport {
        didSet {
            textEditor?.place(viewport)
            needsDisplay = true
        }
    }

    var spaceDown = false {
        didSet { if spaceDown != oldValue { refreshCursor() } }
    }

    private enum Gesture {
        case none
        case pan(startPan: CGPoint, start: CGPoint)
        case edit(AnnotationInteraction)
        case crop(CropInteraction)
    }
    private var gesture = Gesture.none

    private var textEditor: InlineTextEditor?

    private var unit: CGFloat { controller.unit }

    init(controller: EditorController) {
        self.controller = controller
        viewport = Viewport(layout: controller.layout, unit: controller.unit)
        super.init(frame: .zero)
        controller.canvas = self
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

    // MARK: Zoom and pan

    private func toDoc(_ p: CGPoint) -> CGPoint { viewport.toDoc(p) }
    private func toView(_ doc: CGPoint) -> CGPoint { viewport.toView(doc) }

    /// Hit tolerance: 6 view points, in document pixels.
    private var tolerance: CGFloat { 6 / viewport.zoom }

    /// The document or the mode changed. `refit` fits the canvas again (entering or leaving crop).
    func documentChanged(refit: Bool = false) {
        let layout = controller.layout
        let resized = layout.canvasSize != viewport.layout.canvasSize
        viewport.layout = layout
        if refit || resized { refitOrClamp(force: refit) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewport.viewSize = newSize
        refitOrClamp(force: false)
    }

    private func refitOrClamp(force: Bool) {
        if force || viewport.fits {
            viewport.fit()
            publishZoom()
        } else {
            viewport.clampPan()
        }
    }

    private func publishZoom() {
        let percent = viewport.percent
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller.zoomPercent != percent else { return }
            self.controller.zoomPercent = percent
        }
    }

    private func setZoom(_ value: CGFloat, anchor: CGPoint) {
        viewport.zoom(to: value, anchor: anchor)
        publishZoom()
    }

    func zoomStep(_ factor: CGFloat) { setZoom(viewport.zoom * factor, anchor: viewport.viewCenter) }

    func zoomToFit() { refitOrClamp(force: true) }

    func zoomToActual() { setZoom(viewport.actualSize, anchor: viewport.viewCenter) }

    override func magnify(with event: NSEvent) {
        setZoom(viewport.zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(viewport.zoom - viewport.actualSize) < 0.001 {
            zoomToFit()
        } else {
            setZoom(viewport.actualSize, anchor: convert(event.locationInWindow, from: nil))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.05
            setZoom(viewport.zoom * exp(amount), anchor: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        viewport.setPan(CGPoint(x: viewport.pan.x + event.scrollingDeltaX * k, y: viewport.pan.y + event.scrollingDeltaY * k))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.125, alpha: 1) : NSColor(white: 0.87, alpha: 1)).setFill()
        bounds.fill()

        let origin = viewport.canvasOrigin
        let canvasRect = viewport.canvasRect

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22, color: CGColor(gray: 0, alpha: dark ? 0.7 : 0.28))
        ctx.setFillColor(CGColor(gray: dark ? 0.2 : 1, alpha: 1))
        ctx.fill(canvasRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: canvasRect)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: viewport.zoom, y: viewport.zoom)
        EditorRenderer.render(state: controller.state, layout: viewport.layout, source: controller.source, unit: unit, ctx: ctx,
                              baseScale: window?.backingScaleFactor ?? 2, hideTextOf: textEditor?.id)
        ctx.restoreGState()

        if let session = controller.mode.crop {
            CropInteraction.drawOverlay(ctx, session: session, viewport: viewport, viewBounds: bounds)
        } else {
            AnnotationInteraction.drawSelection(ctx, controller: controller, viewport: viewport)
        }
        if case .edit(let drag) = gesture { drag.drawMarquee(ctx, viewport: viewport) }
    }

    // MARK: Hit testing

    private func annotation(withID id: UUID) -> Annotation? {
        controller.state.annotations.first { $0.id == id }
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
            gesture = .pan(startPan: viewport.pan, start: vp)
            NSCursor.closedHand.set()
            return
        }
        let dp = toDoc(vp)
        let shift = event.modifierFlags.contains(.shift)

        if controller.mode.crop != nil {
            gesture = .crop(CropInteraction(mouseDownAt: dp, view: vp, controller: controller, viewport: viewport))
            return
        }

        if let (a, handle) = handleHit(at: vp) {
            gesture = .edit(.resize(a, handle: handle, controller: controller))
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
                gesture = .edit(.move(from: dp, controller: controller))
            } else {
                if !shift { controller.select([]) }
                gesture = .edit(.marquee(from: dp, additive: shift, controller: controller))
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
                gesture = .edit(.move(from: dp, controller: controller))
            } else {
                gesture = .edit(.create(kind, at: dp, controller: controller))
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
            viewport.setPan(CGPoint(x: startPan.x + vp.x - start.x, y: startPan.y + vp.y - start.y))

        case .edit(var drag):
            drag.dragged(to: dp, constrain: shift, zoom: viewport.zoom, controller: controller)
            gesture = .edit(drag)

        case .crop(let crop):
            crop.dragged(to: dp, controller: controller)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = .none
        switch finished {
        case .edit(let drag):
            drag.ended(zoom: viewport.zoom, controller: controller)
            if drag.marquee != nil { needsDisplay = true }
        case .pan:
            refreshCursor()
        case .crop(let crop):
            crop.ended(controller: controller)
        default:
            break
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
            CropInteraction.cursor(at: vp, doc: dp, session: session, viewport: viewport).set()
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
        let editor = InlineTextEditor(id: id, text: text, since: before ?? controller.checkpoint(), controller: controller) { [weak self] in
            self?.finishTextEditing()
        }
        textEditor = editor
        editor.attach(to: self, viewport: viewport)
        needsDisplay = true
    }

    func finishTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        if editor.end() { window?.makeFirstResponder(self) }
        needsDisplay = true
    }
}
