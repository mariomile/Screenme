import AppKit
import Combine

enum EditorSheet: Identifiable {
    case resizeImage, resizeCanvas
    var id: Int { self == .resizeImage ? 0 : 1 }
}

/// All editor state for one open capture: the document, undo history, tool and style, and output.
/// The canvas view draws it; the SwiftUI toolbar and inspector bind to it.
@MainActor
final class EditorController: ObservableObject {
    let item: CaptureItem
    let source: ImageSource
    var unit: CGFloat { source.unit }

    /// The document. It changes only through `update` and `perform` (and undo), so every change
    /// redraws the canvas and tells SwiftUI here.
    private(set) var state: EditState {
        didSet {
            canvas?.documentChanged()
            notify()
        }
    }
    private(set) var savedState: EditState
    private var history = UndoHistory()
    private var annotationClipboard: [Annotation] = []

    @Published private(set) var mode = Mode.select
    @Published var selection: Set<UUID> = []
    @Published var styles: [ToolKind: ToolStyle]
    @Published var zoomPercent = 100
    @Published var sheet: EditorSheet?
    @Published var presets: [BackgroundPreset]

    weak var canvas: CanvasView?
    weak var window: NSWindow?

    init(item: CaptureItem, source: ImageSource) {
        self.item = item
        self.source = source
        var initial = EditState(cropRect: source.bounds)
        initial.background = EditorStore.background()
        initial.spotlightDim = Prefs[Pref.editorSpotlightDim]
        state = initial
        savedState = initial
        styles = Dictionary(uniqueKeysWithValues: ToolKind.allCases.map { ($0, EditorStore.style(for: $0)) })
        presets = EditorStore.presets()
    }

    func notify() { objectWillChange.send() }

    var isDirty: Bool { state != savedState }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// The document as it is now is what the file holds.
    func markSaved() { savedState = state }

    // MARK: Layout

    /// How far a crop can reach: the image, plus any canvas added around it.
    var cropLimit: CGRect { source.bounds.union(state.cropRect) }

    /// What the canvas shows. While cropping, the whole image is shown without the background wrap.
    var layout: Layout {
        mode.crop != nil ? Layout.make(crop: cropLimit, background: nil) : state.exportLayout
    }

    /// Size of the exported picture in pixels.
    var outputSize: CGSize {
        let size = state.exportLayout.canvasSize
        return CGSize(width: (size.width * state.outputScale).rounded(), height: (size.height * state.outputScale).rounded())
    }

    // MARK: Undo

    typealias Checkpoint = UndoHistory.Checkpoint

    /// A drag, a slider or an inline text edit takes a checkpoint when it starts, changes the document
    /// with `update`, and ends with `commit(since:)`.
    func checkpoint() -> Checkpoint { history.checkpoint(state) }

    /// Changes the document without an undo step of its own: the interaction around it commits.
    func update(_ change: (inout EditState) -> Void) {
        change(&state)
    }

    /// Makes everything since `before` one undo step (see `UndoHistory.commit`).
    func commit(since before: Checkpoint, coalesce key: String? = nil) {
        history.commit(from: before, to: state, coalesce: key)
        notify()
    }

    /// A one-shot edit: one undo step.
    func perform(_ change: (inout EditState) -> Void) {
        let before = checkpoint()
        update(change)
        commit(since: before)
    }

    func undo() {
        canvas?.finishTextEditing()
        guard let previous = history.undo(from: state) else { return }
        state = previous
        pruneSelection()
    }

    func redo() {
        canvas?.finishTextEditing()
        guard let next = history.redo(from: state) else { return }
        state = next
        pruneSelection()
    }

    private func pruneSelection() {
        let ids = Set(state.annotations.map(\.id))
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
    }

    // MARK: Tools

    /// Switches tool. Picking the current one again does nothing, so a crop in progress survives.
    func choose(_ choice: ToolChoice) {
        guard choice != mode.choice else { return }
        let wasCropping = mode.crop != nil
        canvas?.finishTextEditing()
        switch choice {
        case .select:
            mode = .select
        case .draw(let kind):
            selection = []
            mode = .draw(kind)
        case .crop:
            selection = []
            mode = .crop(CropSession(rect: state.cropRect))
        }
        canvas?.documentChanged(refit: wasCropping || mode.crop != nil)
        canvas?.refreshCursor()
        focusCanvas()
    }

    /// Gives the keyboard back to the canvas after a toolbar or inspector control, so Delete, Esc, Return,
    /// arrows and tool letters keep working. A text field being typed in keeps it.
    func focusCanvas() {
        guard let canvas, let window = canvas.window, !(window.firstResponder is NSText),
              window.firstResponder !== canvas else { return }
        window.makeFirstResponder(canvas)
    }

    // MARK: Selection and arrangement

    var selectedAnnotations: [Annotation] { state.annotations.filter { selection.contains($0.id) } }

    /// The tool whose style the inspector shows: the selected annotation's kind, or the active drawing tool.
    var contextKind: ToolKind? {
        let kinds = Set(selectedAnnotations.map(\.kind))
        if kinds.count == 1 { return kinds.first }
        if kinds.count > 1 { return nil }
        return mode.drawKind
    }

    var contextStyle: ToolStyle? {
        guard let kind = contextKind else { return nil }
        return selectedAnnotations.first?.style ?? styles[kind]
    }

    /// Applies a style change to the selection and remembers it as the kind's style, without an undo step:
    /// for slider drags, which commit when they end.
    func applyStyle(_ change: (inout ToolStyle) -> Void) {
        guard let kind = contextKind else { return }
        let ids = selection
        var remembered = contextStyle ?? kind.traits.style
        change(&remembered)
        styles[kind] = remembered
        EditorStore.save(style: remembered, for: kind)
        guard !ids.isEmpty else { return }
        update { s in
            for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                change(&s.annotations[i].style)
            }
        }
    }

    /// A style change as one undo step.
    func updateStyle(_ change: (inout ToolStyle) -> Void) {
        let before = checkpoint()
        applyStyle(change)
        commit(since: before)
    }

    /// The custom color well. The color panel sends a stream of colors while the user drags in it:
    /// they make one undo step as long as nothing else happens in between.
    func setColor(_ color: RGBA) {
        let before = checkpoint()
        applyStyle { $0.color = color }
        commit(since: before, coalesce: "color " + selection.map(\.uuidString).sorted().joined())
    }

    /// Sets the document's spotlight dim and remembers it for the next document, without an undo step.
    func applySpotlightDim(_ dim: Double) {
        update { $0.spotlightDim = dim }
        Prefs[Pref.editorSpotlightDim] = dim
    }

    func select(_ ids: Set<UUID>) {
        if selection != ids { selection = ids }
        canvas?.needsDisplay = true
    }

    func selectAll() {
        choose(.select)
        selection = Set(state.annotations.map(\.id))
        canvas?.needsDisplay = true
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { $0.annotations.removeAll { ids.contains($0.id) } }
        selection = []
    }

    func duplicateSelection() {
        let originals = selectedAnnotations
        guard !originals.isEmpty else { return }
        let offset = 16 * unit
        var created: [Annotation] = []
        perform { s in
            for var copy in originals {
                copy.id = UUID()
                copy.translate(dx: offset, dy: offset)
                s.annotations.append(copy)
                created.append(copy)
            }
        }
        selection = Set(created.map(\.id))
    }

    func copySelection() -> Bool {
        let selected = selectedAnnotations
        guard !selected.isEmpty else { return false }
        annotationClipboard = selected
        return true
    }

    func pasteAnnotations() -> Bool {
        guard !annotationClipboard.isEmpty else { return false }
        var created: [Annotation] = []
        perform { s in
            for var copy in annotationClipboard {
                copy.id = UUID()
                copy.translate(dx: 20 * unit, dy: 20 * unit)
                s.annotations.append(copy)
                created.append(copy)
            }
        }
        annotationClipboard = created
        selection = Set(created.map(\.id))
        return true
    }

    enum ArrangeMove { case front, forward, backward, back }

    func arrange(_ move: ArrangeMove) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { s in
            var list = s.annotations
            switch move {
            case .front:
                let picked = list.filter { ids.contains($0.id) }
                list.removeAll { ids.contains($0.id) }
                list.append(contentsOf: picked)
            case .back:
                let picked = list.filter { ids.contains($0.id) }
                list.removeAll { ids.contains($0.id) }
                list.insert(contentsOf: picked, at: 0)
            case .forward:
                for i in stride(from: list.count - 2, through: 0, by: -1) where ids.contains(list[i].id) && !ids.contains(list[i + 1].id) {
                    list.swapAt(i, i + 1)
                }
            case .backward:
                for i in 1..<max(list.count, 1) where ids.contains(list[i].id) && !ids.contains(list[i - 1].id) {
                    list.swapAt(i, i - 1)
                }
            }
            s.annotations = list
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { s in
            for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                s.annotations[i].translate(dx: dx * unit, dy: dy * unit)
            }
        }
    }

    // MARK: Crop

    /// Changes the crop being set up. Does nothing outside the crop tool.
    func updateCrop(_ change: (inout CropSession) -> Void) {
        guard case .crop(var session) = mode else { return }
        change(&session)
        mode = .crop(session)
        canvas?.needsDisplay = true
    }

    func setCropAspect(_ aspect: CropAspect) {
        updateCrop { session in
            session.aspect = aspect
            if let ratio = aspect.ratio { session.rect = CropMath.fit(session.rect, ratio: ratio) }
        }
    }

    func resetCropSelection() {
        let limit = cropLimit
        updateCrop { $0 = CropSession(rect: limit) }
    }

    func applyCrop() {
        guard let session = mode.crop else { return }
        let rect = session.rect.integral.intersection(cropLimit)
        choose(.select)
        if rect.width >= 4, rect.height >= 4, rect != state.cropRect {
            perform { $0.cropRect = rect }
        }
    }

    func cancelCrop() {
        choose(.select)
    }

    /// Back to the full image.
    func resetCrop() {
        guard state.cropRect != source.bounds else { return }
        perform { $0.cropRect = source.bounds }
    }

    // MARK: Resize

    func resizeImage(toWidth width: CGFloat) {
        let base = state.exportLayout.canvasSize.width
        guard base > 0, width >= 1 else { return }
        perform { $0.outputScale = width / base }
    }

    func resizeCanvas(width: CGFloat, height: CGFloat, anchor: Alignment9, fill: RGBA) {
        guard width >= 4, height >= 4, width <= 30_000, height <= 30_000 else { return }
        perform { s in
            let c = s.cropRect
            s.cropRect = CGRect(x: c.minX + (c.width - width) * anchor.fx,
                                y: c.minY + (c.height - height) * anchor.fy,
                                width: width, height: height)
            s.canvasFill = fill
        }
    }

    // MARK: Background

    func toggleBackground() {
        if mode.crop != nil { cancelCrop() }
        updateBackground { $0.enabled.toggle() }
    }

    /// Changes the background and remembers it for the next document, without an undo step.
    func applyBackground(_ change: (inout BackgroundSettings) -> Void) {
        update { change(&$0.background) }
        EditorStore.save(background: state.background)
    }

    /// A background change as one undo step.
    func updateBackground(_ change: (inout BackgroundSettings) -> Void) {
        let before = checkpoint()
        applyBackground(change)
        commit(since: before)
    }

    /// The custom background color well: one undo step per color panel drag, like `setColor`.
    func setBackgroundColor(_ color: RGBA) {
        let before = checkpoint()
        applyBackground { $0.fill = .solid(color) }
        commit(since: before, coalesce: "background color")
    }

    func savePreset(named name: String) {
        var settings = state.background
        settings.enabled = true
        presets.append(BackgroundPreset(name: name, settings: settings))
        EditorStore.save(presets: presets)
    }

    func applyPreset(_ preset: BackgroundPreset) {
        updateBackground { $0 = preset.settings }
    }

    func deletePreset(_ preset: BackgroundPreset) {
        presets.removeAll { $0.id == preset.id }
        EditorStore.save(presets: presets)
    }

    // MARK: Zoom

    func zoomIn() { canvas?.zoomStep(1.25) }
    func zoomOut() { canvas?.zoomStep(0.8) }
    func zoomFit() { canvas?.zoomToFit() }
    func zoomActual() { canvas?.zoomToActual() }
}
