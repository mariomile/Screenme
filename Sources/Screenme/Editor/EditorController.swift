import AppKit
import Combine
import UniformTypeIdentifiers

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

    /// The document. Mutating it redraws the canvas; SwiftUI is told separately with `notify()`.
    var state: EditState {
        didSet { canvas?.documentChanged() }
    }
    private(set) var savedState: EditState
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var pendingSnapshot: EditState?
    private var annotationClipboard: [Annotation] = []

    @Published private(set) var mode = Mode.select
    @Published var selection: Set<UUID> = []
    @Published var styles: [ToolKind: ToolStyle]
    @Published var zoomPercent = 100
    @Published var sheet: EditorSheet?
    @Published var presets: [BackgroundPreset]
    @Published var isEditingText = false

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
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

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

    func beginChange() {
        if pendingSnapshot == nil { pendingSnapshot = state }
    }

    func endChange() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        if snapshot != state {
            undoStack.append(snapshot)
            if undoStack.count > 300 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        notify()
    }

    func perform(_ change: (inout EditState) -> Void) {
        beginChange()
        change(&state)
        endChange()
    }

    func undo() {
        canvas?.finishTextEditing()
        endChange()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        pruneSelection()
        notify()
    }

    func redo() {
        canvas?.finishTextEditing()
        endChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        pruneSelection()
        notify()
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

    /// Applies a style change to the selection (undoably) and remembers it as the tool's style.
    /// Pass `live: true` for slider drags: the caller brackets them with `beginChange()` and `endChange()`.
    func updateStyle(live: Bool = false, _ change: (inout ToolStyle) -> Void) {
        guard let kind = contextKind else { return }
        let ids = selection
        if !live { beginChange() }
        var remembered = contextStyle ?? .defaults(for: kind)
        change(&remembered)
        styles[kind] = remembered
        EditorStore.save(style: remembered, for: kind)
        if !ids.isEmpty {
            var s = state
            for i in s.annotations.indices where ids.contains(s.annotations[i].id) {
                change(&s.annotations[i].style)
            }
            state = s
        }
        if !live { endChange() }
        notify()
    }

    /// Sets the document's spotlight dim and remembers it for the next document.
    /// Pass `live: true` for slider drags: the caller brackets them with `beginChange()` and `endChange()`.
    func setSpotlightDim(_ dim: Double, live: Bool = false) {
        if !live { beginChange() }
        state.spotlightDim = dim
        Prefs[Pref.editorSpotlightDim] = dim
        if !live { endChange() }
        notify()
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

    private var colorSettleTask: Task<Void, Never>?

    /// A color picker drags continuously: group the drag into one undo step that closes when it goes quiet.
    private func settleLater() {
        colorSettleTask?.cancel()
        colorSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endChange()
        }
    }

    func setColorLive(_ color: RGBA) {
        beginChange()
        updateStyle(live: true) { $0.color = color }
        settleLater()
    }

    func setBackgroundColorLive(_ color: RGBA) {
        beginChange()
        updateBackground(live: true) { $0.fill = .solid(color) }
        settleLater()
    }

    func updateBackground(live: Bool = false, _ change: (inout BackgroundSettings) -> Void) {
        if !live { beginChange() }
        var s = state
        change(&s.background)
        state = s
        EditorStore.save(background: s.background)
        if !live { endChange() }
        notify()
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

    // MARK: Output

    /// Pixels for the current document in the file's own format family.
    private func flatten(for url: URL) -> (CGImage, UTType)? {
        let jpeg = ImageFormat(of: url) == .jpg
        guard let image = EditorRenderer.flatten(state: state, source: source, opaque: jpeg) else { return nil }
        return (image, jpeg ? .jpeg : .png)
    }

    private func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * unit * state.outputScale
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = Prefs[Pref.jpegQuality] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Done: flattens, overwrites the capture file in place, tells the rest of the app, closes.
    func save() {
        canvas?.finishTextEditing()
        if mode.crop != nil { applyCrop() }
        guard let (image, type) = flatten(for: item.url), let data = encode(image, as: type) else {
            alert("Screenme could not render the image.")
            return
        }
        do {
            try data.write(to: item.url, options: .atomic)
        } catch {
            alert("Screenme could not save the image: \(error.localizedDescription)")
            return
        }
        savedState = state
        NotificationCenter.default.post(name: .captureUpdated, object: item.url)
        if Prefs[Pref.afterShotCopy] { Clipboard.copyImage(at: item.url) }
        window?.close()
    }

    /// Copies the flattened image without closing.
    func copyImage() {
        canvas?.finishTextEditing()
        guard let image = EditorRenderer.flatten(state: state, source: source, opaque: false),
              let data = encode(image, as: .png) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
        CaptureAction.copy.confirm()
    }

    func saveAs() {
        canvas?.finishTextEditing()
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = Storage.saveDirectory
        panel.canCreateDirectories = true
        let stem = item.url.deletingPathExtension().lastPathComponent
        let startJPEG = ImageFormat(of: item.url) == .jpg
        panel.allowedContentTypes = [startJPEG ? .jpeg : .png]
        panel.nameFieldStringValue = "\(stem).\(startJPEG ? "jpg" : "png")"

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: startJPEG ? 1 : 0)
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        panel.accessoryView = row
        let handler = FormatPopupHandler(panel: panel, stem: stem)
        popup.target = handler
        popup.action = #selector(FormatPopupHandler.changed(_:))

        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(handler) {}
            guard response == .OK, let url = panel.url, let self else { return }
            let jpeg = popup.indexOfSelectedItem == 1
            guard let image = EditorRenderer.flatten(state: self.state, source: self.source, opaque: jpeg),
                  let data = self.encode(image, as: jpeg ? .jpeg : .png) else { return }
            do {
                try data.write(to: url, options: .atomic)
                CaptureAction.saveAs.confirm(savedTo: url)
            } catch {
                self.alert("Screenme could not save the image: \(error.localizedDescription)")
            }
        }
    }

    /// A file holding the flattened image, for dragging out of the toolbar.
    func dragFile() -> URL? {
        canvas?.finishTextEditing()
        guard let (image, type) = flatten(for: item.url), let data = encode(image, as: type) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeEditorDrag/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(item.url.lastPathComponent)
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    // MARK: Closing

    /// Asks what to do with unsaved edits. Returns true when the window may close right away.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas?.finishTextEditing()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to this screenshot?"
        alert.informativeText = "Your annotations will be lost if you don't save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save()
            case .alertSecondButtonReturn:
                self.savedState = self.state
                sender.close()
            default:
                break
            }
        }
        return false
    }

    // MARK: Keyboard

    /// Called from the window's key monitor. Returns true when the event was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let inTextField = window?.firstResponder is NSText

        if isEditingText {
            if event.keyCode == 53 || (mods == .command && (event.keyCode == 36 || event.keyCode == 76)) {
                canvas?.finishTextEditing()
                return true
            }
        }

        if mods.contains(.command) {
            if inTextField, let selector = editSelector(for: key, shift: mods.contains(.shift)) {
                NSApp.sendAction(selector, to: nil, from: nil)
                return true
            }
            let shift = mods.contains(.shift)
            let option = mods.contains(.option)
            switch key {
            case "z": shift ? redo() : undo(); return true
            case "s": shift ? saveAs() : save(); return true
            case "c":
                guard !inTextField else { return false }
                if !copySelection() { copyImage() }
                return true
            case "v": return inTextField ? false : pasteAnnotations()
            case "d": duplicateSelection(); return true
            case "a": if inTextField { return false }; selectAll(); return true
            case "]": arrange(option ? .front : .forward); return true
            case "[": arrange(option ? .back : .backward); return true
            case "=", "+": zoomIn(); return true
            case "-": zoomOut(); return true
            case "0": zoomFit(); return true
            case "1": zoomActual(); return true
            case "w": window?.performClose(nil); return true
            default: return false
            }
        }

        guard !inTextField else { return false }

        switch event.keyCode {
        case 36, 76: // Return, Enter
            if mode.crop != nil { applyCrop() } else { save() }
            return true
        case 53: // Escape
            if mode.crop != nil { cancelCrop() } else if !selection.isEmpty { select([]) }
            return true
        case 51, 117: // Delete, Forward Delete
            deleteSelection()
            return true
        case 123: nudge(dx: mods.contains(.shift) ? -10 : -1, dy: 0); return true
        case 124: nudge(dx: mods.contains(.shift) ? 10 : 1, dy: 0); return true
        case 125: nudge(dx: 0, dy: mods.contains(.shift) ? 10 : 1); return true
        case 126: nudge(dx: 0, dy: mods.contains(.shift) ? -10 : -1); return true
        default: break
        }

        if mods.isEmpty || mods == .shift, let match = ToolChoice.all.first(where: { $0.key == key }) {
            choose(match)
            return true
        }
        return false
    }

    private func editSelector(for key: String, shift: Bool) -> Selector? {
        switch key {
        case "z": return Selector(shift ? ("redo:") : ("undo:"))
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }
}

/// Keeps the save panel's file extension in step with the format popup.
@MainActor
final class FormatPopupHandler: NSObject {
    private let panel: NSSavePanel
    private let stem: String

    init(panel: NSSavePanel, stem: String) {
        self.panel = panel
        self.stem = stem
    }

    @objc func changed(_ sender: NSPopUpButton) {
        let jpeg = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [jpeg ? .jpeg : .png]
        let current = panel.nameFieldStringValue as NSString
        let base = current.deletingPathExtension.isEmpty ? stem : current.deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(jpeg ? "jpg" : "png")"
    }
}
