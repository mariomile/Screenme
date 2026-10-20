import AppKit

/// A mouse drag that edits annotations: drawing a new one, moving the selection, dragging a handle, or
/// marquee selecting. It keeps the document from before it started and commits one undo step when the
/// mouse goes up. It also draws the selection chrome. The crop tool has its own, `CropInteraction`.
@MainActor
struct AnnotationInteraction {
    private enum Action {
        case create(id: UUID, start: CGPoint)
        case move(last: CGPoint)
        case resize(id: UUID, handle: Handle, original: Annotation)
        case marquee(start: CGPoint, additive: Bool, base: Set<UUID>)
    }

    private var action: Action
    private let before: EditorController.Checkpoint
    /// The marquee being dragged, in document pixels.
    private(set) var marquee: CGRect?

    private init(_ action: Action, controller: EditorController) {
        self.action = action
        before = controller.checkpoint()
    }

    /// Adds a new annotation of `kind` at `p`, to be dragged out.
    static func create(_ kind: ToolKind, at p: CGPoint, controller: EditorController) -> AnnotationInteraction {
        let a = Annotation(kind: kind, style: controller.styles[kind] ?? kind.traits.style, at: p)
        let drag = AnnotationInteraction(.create(id: a.id, start: p), controller: controller)
        controller.update { $0.annotations.append(a) }
        return drag
    }

    /// Moves the selection.
    static func move(from p: CGPoint, controller: EditorController) -> AnnotationInteraction {
        AnnotationInteraction(.move(last: p), controller: controller)
    }

    static func resize(_ a: Annotation, handle: Handle, controller: EditorController) -> AnnotationInteraction {
        AnnotationInteraction(.resize(id: a.id, handle: handle, original: a), controller: controller)
    }

    /// Selects what a rect from `p` touches. `additive` (Shift) adds to the current selection.
    static func marquee(from p: CGPoint, additive: Bool, controller: EditorController) -> AnnotationInteraction {
        AnnotationInteraction(.marquee(start: p, additive: additive, base: controller.selection), controller: controller)
    }

    /// `p` in document pixels; `constrain` is Shift; `zoom` is view points per document pixel.
    mutating func dragged(to p: CGPoint, constrain: Bool, zoom: CGFloat, controller: EditorController) {
        switch action {
        case .create(let id, let start):
            Self.modify(id, controller) { $0.dragOut(from: start, to: p, constrain: constrain, minStep: 1.5 / zoom) }
        case .move(let last):
            let dx = p.x - last.x, dy = p.y - last.y
            let ids = controller.selection
            controller.update { s in
                for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                    s.annotations[i].translate(dx: dx, dy: dy)
                }
            }
            action = .move(last: p)
        case .resize(let id, let handle, let original):
            let unit = controller.unit
            Self.modify(id, controller) { $0.apply(handle: handle, to: p, original: original, unit: unit, constrain: constrain) }
        case .marquee(let start, let additive, let base):
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee = r
            var ids = additive ? base : []
            for a in controller.state.annotations where a.bounds(unit: controller.unit).intersects(r) { ids.insert(a.id) }
            controller.select(ids)
        }
    }

    /// A new annotation too small to keep (a click without a drag) is dropped; a kept one is selected.
    func ended(zoom: CGFloat, controller: EditorController) {
        if case .create(let id, _) = action, let a = controller.state.annotations.first(where: { $0.id == id }) {
            if a.isTooSmall(minLength: 5 / zoom) {
                controller.update { $0.annotations.removeAll { $0.id == id } }
            } else {
                controller.select([id])
            }
        }
        controller.commit(since: before)
    }

    private static func modify(_ id: UUID, _ controller: EditorController, _ change: (inout Annotation) -> Void) {
        controller.update { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { change(&s.annotations[i]) }
        }
    }

    // MARK: Drawing

    /// Outlines the selected annotations, with handles when one is selected.
    static func drawSelection(_ ctx: CGContext, controller: EditorController, viewport: Viewport) {
        let accent = NSColor.controlAccentColor
        let unit = controller.unit
        let single = controller.selection.count == 1
        for a in controller.selectedAnnotations {
            if case .segment = a.shape {
                // A thin highlight along the line shows what is selected.
                let pts = a.centerline().map { viewport.toView($0) }
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
                let r = viewport.toView(a.bounds(unit: unit)).insetBy(dx: -2, dy: -2)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.25)
                if case .stroke = a.shape { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
                ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
            }
            if single {
                for (_, p) in a.handlePoints(unit: unit) { drawHandle(ctx, at: viewport.toView(p), accent: accent) }
            }
        }
    }

    private static func drawHandle(_ ctx: CGContext, at p: CGPoint, accent: NSColor) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
        ctx.fillEllipse(in: r.insetBy(dx: -1.5, dy: -1.5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.75)
        ctx.strokeEllipse(in: r.insetBy(dx: 0.9, dy: 0.9))
    }

    func drawMarquee(_ ctx: CGContext, viewport: Viewport) {
        guard let marquee else { return }
        let r = viewport.toView(marquee)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }
}
