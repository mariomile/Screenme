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
        markSaved()
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

    /// A file holding the flattened image, for dragging out of the toolbar and sharing.
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
                self.markSaved()
                sender.close()
            default:
                break
            }
        }
        return false
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
