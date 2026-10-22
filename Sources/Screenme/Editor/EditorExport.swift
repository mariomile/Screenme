import AppKit
import UniformTypeIdentifiers

/// Turning the document into pixels and files: Done, Copy, Save As, drag out, and the save prompt on close.
extension EditorController {
    // MARK: Output

    /// Pixels for the current document in the file's own format family.
    private func flatten(for url: URL) -> (CGImage, UTType)? {
        let jpeg = ImageFormat(of: url) == .jpg
        guard let image = EditorRenderer.flatten(state: state, source: source, opaque: jpeg) else { return nil }
        return (image, jpeg ? .jpeg : .png)
    }

    private func encode(_ image: CGImage, as type: UTType) -> Data? {
        flattened(image, as: type).encoded()
    }

    private func flattened(_ image: CGImage, as type: UTType) -> FlattenedImage {
        FlattenedImage(image: image, type: type, dpi: 72 * unit * state.outputScale,
                       jpegQuality: Prefs[Pref.jpegQuality], name: item.url.lastPathComponent)
    }

    /// The document flattened for a drag out. Encoding waits until the receiver asks for the file, off the main thread.
    func dragExport() -> FlattenedImage? {
        canvas?.finishTextEditing()
        guard let (image, type) = flatten(for: item.url) else { return nil }
        return flattened(image, as: type)
    }

    /// Done: flattens, overwrites the capture file in place, tells the rest of the app, closes.
    func save() {
        guard writeToCapture() else { return }
        if Prefs[Pref.afterShotCopy] { Clipboard.copyImage(at: item.url) }
        window?.close()
    }

    /// Copies the flattened image. With "Close editor after copying" it also saves and closes, like Done.
    func copyImage() {
        canvas?.finishTextEditing()
        guard let image = EditorRenderer.flatten(state: state, source: source, opaque: false),
              let data = encode(image, as: .png) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
        CaptureAction.copy.confirm()
        if Prefs[Pref.editorCloseAfterCopy], writeToCapture() { window?.close() }
    }

    /// Copy for AI: the edited image, with the notes on annotations in the text. The text names a file
    /// holding exactly what was copied (redacted with "Hide sensitive info when sharing"). With "Close editor after copying" it also saves and closes.
    func copyForAI() {
        canvas?.finishTextEditing()
        guard let image = EditorRenderer.flatten(state: state, source: source, opaque: false),
              let png = encode(image, as: .png), let file = shareFile() else { return }
        CaptureContexts.setNotes(notes, for: item.url)
        Task {
            guard let hidden = await AIClipboard.copy(image: image, png: png, path: file, captureURL: item.url,
                                                      unit: source.unit * state.outputScale) else {
                Feedback.failure("Could not read the text")
                return
            }
            CaptureAction.copyForAI.confirm(hidden: hidden)
            if Prefs[Pref.editorCloseAfterCopy], writeToCapture() { window?.close() }
        }
    }

    /// The notes on annotations, in drawing order, each naming what it points at for an AI reading the image.
    var notes: [String] {
        var counter = 0
        let crop = state.cropRect
        return state.annotations.compactMap { a in
            if a.kind == .counter { counter += 1 }
            let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return nil }
            if a.kind == .counter { return "Marker \(counter): \(note)" }
            let box = a.bounds(unit: unit)
            let column = ["left", "center", "right"][min(2, max(0, Int((box.midX - crop.minX) / crop.width * 3)))]
            let row = ["top", "middle", "bottom"][min(2, max(0, Int((box.midY - crop.minY) / crop.height * 3)))]
            let place = row == "middle" && column == "center" ? "center" : "\(row) \(column)"
            return "\(a.kind.traits.title) at the \(place): \(note)"
        }
    }

    /// Saves the document in the capture's edit sidecar, overwrites the capture file with it flattened,
    /// and tells the rest of the app. False on failure, after an alert.
    func writeToCapture() -> Bool {
        canvas?.finishTextEditing()
        if mode.crop != nil { applyCrop() }
        guard let (image, type) = flatten(for: item.url), let data = encode(image, as: type) else {
            Feedback.alert("Screenme could not render the image.", over: window)
            return false
        }
        do {
            try EditSidecar.save(state, flattened: data, to: item.url)
        } catch {
            Feedback.alert("Screenme could not save the image: \(error.localizedDescription)", over: window)
            return false
        }
        markSaved()
        CaptureContexts.setNotes(notes, for: item.url)
        NotificationCenter.default.post(name: .captureUpdated, object: item.url)
        return true
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
                Feedback.alert("Screenme could not save the image: \(error.localizedDescription)", over: window)
            }
        }
    }

    /// A temporary copy of the flattened image named like the capture (`TemporaryCopies`), for Share and for the
    /// file Copy for AI names in its text. Each one overwrites the last.
    func shareFile() -> URL? {
        canvas?.finishTextEditing()
        guard let (image, type) = flatten(for: item.url), let data = encode(image, as: type) else { return nil }
        return TemporaryCopies.write(data, named: item.url.lastPathComponent)
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
                self.markSaved()
                sender.close()
            default:
                break
            }
        }
        return false
    }
}

/// Flattened pixels and how to encode them. Immutable, so a drag out can encode it on its own queue.
struct FlattenedImage: @unchecked Sendable {
    let image: CGImage
    let type: UTType
    let dpi: CGFloat
    let jpegQuality: Double
    /// The file name a drag out offers.
    let name: String

    func encoded() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
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
