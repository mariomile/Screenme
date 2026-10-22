import AppKit
import Combine
import SwiftUI

/// The annotation editor. One window per open capture.
@MainActor
enum AnnotationEditor {
    /// Owns each window's toolbar delegate and key monitor; `WindowPresenter` owns the windows.
    private static var editors: [UUID: EditorWindow] = [:]

    static func windowID(for item: CaptureItem) -> String { "editor-\(item.id.uuidString)" }

    static func open(_ item: CaptureItem) {
        // A GIF would be flattened to its first frame and saved as PNG bytes over the animation.
        guard item.kind == .image else { return }
        if WindowPresenter.shared.focus(windowID(for: item)) { return }
        guard let controller = controller(for: item) else {
            Feedback.failure("Screenme could not open \(item.url.lastPathComponent)", duration: 3.2)
            return
        }
        editors[item.id] = EditorWindow(controller: controller) { editors[item.id] = nil }
    }

    /// The document for a capture. One saved from the editor before opens as it was captured,
    /// with its annotations live again (`EditSidecar`). Nil when the image cannot be read.
    static func controller(for item: CaptureItem) -> EditorController? {
        let saved = EditSidecar.load(for: item.url)
        guard let source = ImageSource.load(url: saved?.original ?? item.url) else { return nil }
        return EditorController(item: item, source: source, saved: saved?.state)
    }
}

/// Owns the window, its toolbar and its Cmd shortcuts for one capture.
@MainActor
private final class EditorWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let controller: EditorController
    private let window: NSWindow
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var changes: AnyCancellable?
    private let onClose: () -> Void

    private static let leading = NSToolbarItem.Identifier("screenme.editor.leading")
    private static let tools = NSToolbarItem.Identifier("screenme.editor.tools")
    private static let trailing = NSToolbarItem.Identifier("screenme.editor.trailing")

    init(controller: EditorController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose

        let visible = WindowPresenter.activeScreen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let imageSize = CGSize(width: controller.source.size.width / controller.unit, height: controller.source.size.height / controller.unit)
        let size = CGSize(width: min(max(imageSize.width + 140, 1020), visible.width * 0.92),
                          height: min(max(imageSize.height + 52 + 140, 640), visible.height * 0.9))

        window = WindowPresenter.shared.show(AnnotationEditor.windowID(for: controller.item),
                                             title: controller.item.url.lastPathComponent,
                                             size: size,
                                             style: [.titled, .closable, .miniaturizable, .resizable],
                                             sizingOptions: []) {
            EditorRootView(c: controller)
        }
        super.init()

        window.setContentSize(size)
        window.contentMinSize = CGSize(width: 980, height: 600)
        window.titleVisibility = .hidden
        window.delegate = self
        controller.window = window

        let toolbar = NSToolbar(identifier: "screenme.editor.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        WindowPresenter.center(window)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
        changes = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncEditedDot() }
        }
    }

    private func syncEditedDot() {
        window.isDocumentEdited = controller.isDirty
    }

    private func teardown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        changes = nil
        controller.canvas = nil
        onClose()
    }

    // MARK: Keyboard

    /// Returns true when the event was used and must not travel on.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, let action = command(for: event) else { return false }
        action()
        return true
    }

    /// The Cmd shortcuts. A menu bar app has no Edit menu to hold them, so this table stands in for one.
    /// While a text field has focus, the standard edit commands go to it through the responder chain.
    /// Plain keys are not here: the canvas handles them in `keyDown` when it has focus.
    private func command(for event: NSEvent) -> (() -> Void)? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) else { return nil }
        let shift = mods.contains(.shift), option = mods.contains(.option)
        let typing = window.firstResponder is NSText
        let c = controller
        let window = window
        func send(_ action: Selector) -> () -> Void { { NSApp.sendAction(action, to: nil, from: nil) } }

        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "z": return typing ? send(shift ? Selector(("redo:")) : Selector(("undo:"))) : (shift ? c.redo : c.undo)
        case "x": return typing ? send(#selector(NSText.cut(_:))) : nil
        case "c" where shift && !typing: return c.copyForAI
        case "c": return typing ? send(#selector(NSText.copy(_:))) : { if !c.copySelection() { c.copyImage() } }
        case "v": return typing ? send(#selector(NSText.paste(_:))) : { _ = c.pasteAnnotations() }
        case "a": return typing ? send(#selector(NSText.selectAll(_:))) : c.selectAll
        case "s": return shift ? c.saveAs : c.save
        case "d": return c.duplicateSelection
        case "]": return { c.arrange(option ? .front : .forward) }
        case "[": return { c.arrange(option ? .back : .backward) }
        case "=", "+": return c.zoomIn
        case "-": return c.zoomOut
        case "0": return c.zoomFit
        case "1": return c.zoomActual
        case "w": return { window.performClose(nil) }
        default: return nil
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller.windowShouldClose(sender)
    }

    func windowDidResignKey(_ notification: Notification) {
        controller.canvas?.spaceDown = false
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leading, .flexibleSpace, Self.tools, .flexibleSpace, Self.trailing]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leading, Self.tools, Self.trailing, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.leading: return item(itemIdentifier, ToolbarLeading(c: controller))
        case Self.tools: return item(itemIdentifier, ToolPalette(c: controller))
        case Self.trailing: return item(itemIdentifier, ToolbarTrailing(c: controller))
        default: return nil
        }
    }

    private func item<V: View>(_ identifier: NSToolbarItem.Identifier, _ view: V) -> NSToolbarItem {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: ceil(size.width)).isActive = true
        host.heightAnchor.constraint(equalToConstant: max(ceil(size.height), 28)).isActive = true
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = host
        item.isBordered = false
        return item
    }
}
