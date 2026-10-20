import AppKit
import Carbon.HIToolbox

/// Edits a label in place: a text view laid over the canvas in the label's font, color and position.
/// The whole edit is one undo step, from the checkpoint it was started with.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    /// The label being edited. The canvas draws its backdrop but not its glyphs.
    let id: UUID
    private let controller: EditorController
    private let before: EditorController.Checkpoint
    private let textView = InlineTextView(frame: .zero)

    /// `onEnd` is called when the text view finishes the edit itself (Esc, Cmd-Return, losing focus).
    init(id: UUID, text: String, since before: EditorController.Checkpoint, controller: EditorController,
         onEnd: @escaping () -> Void) {
        self.id = id
        self.controller = controller
        self.before = before
        super.init()
        let tv = textView
        tv.onFinish = onEnd
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
    }

    /// Puts the text view on `canvas` with the cursor at the end, and gives it the keyboard.
    func attach(to canvas: NSView, viewport: Viewport) {
        canvas.addSubview(textView)
        place(viewport)
        canvas.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Matches the text view to the label as the text, style or zoom changes.
    func place(_ viewport: Viewport) {
        guard let a = controller.state.annotations.first(where: { $0.id == id }), case .label(let origin, let text) = a.shape else { return }
        let unit = controller.unit
        let layout = TextLayout.layout(text: text, at: origin, style: a.style, unit: unit)
        let p = viewport.toView(layout.textOrigin)
        textView.font = NSFont.systemFont(ofSize: a.style.fontSize * unit * viewport.zoom, weight: a.style.weight.weight)
        let color = TextLayout.textColor(a.style).nsColor
        textView.textColor = color
        textView.insertionPointColor = color
        textView.frame = CGRect(x: p.x, y: p.y, width: layout.textSize.width * viewport.zoom + 14,
                                height: layout.textSize.height * viewport.zoom + 2)
    }

    /// Removes the text view, keeps the text (a blank label is removed) and commits the edit.
    /// Returns true when the text view had the keyboard.
    func end() -> Bool {
        textView.delegate = nil
        let hadFocus = textView.window?.firstResponder === textView
        textView.removeFromSuperview()
        setText(textView.string)
        if let a = controller.state.annotations.first(where: { $0.id == id }), a.isTooSmall(minLength: 0) {
            controller.update { [id] in $0.annotations.removeAll { $0.id == id } }
            controller.select(controller.selection.subtracting([id]))
        }
        controller.commit(since: before)
        return hadFocus
    }

    private func setText(_ text: String) {
        controller.update { [id] s in
            guard let i = s.annotations.firstIndex(where: { $0.id == id }), case .label(let origin, _) = s.annotations[i].shape else { return }
            s.annotations[i].shape = .label(origin: origin, text: text)
        }
    }

    func textDidChange(_ notification: Notification) {
        setText(textView.string)
    }

    func textDidEndEditing(_ notification: Notification) {
        textView.onFinish()
    }
}

/// Escape or Cmd-Return finishes the edit.
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
