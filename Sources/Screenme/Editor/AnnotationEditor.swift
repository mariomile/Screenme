import AppKit
import Combine
import SwiftUI

/// The annotation editor. One window per open capture.
@MainActor
enum AnnotationEditor {
    private static var windows: [UUID: EditorWindow] = [:]

    static func open(_ item: CaptureItem) {
        // A GIF would be flattened to its first frame and saved as PNG bytes over the animation.
        guard item.kind == .image, !item.isGIF else { return }
        if let existing = windows[item.id] {
            existing.bringToFront()
            return
        }
        guard let source = ImageSource.load(url: item.url) else {
            let alert = NSAlert()
            alert.messageText = "Screenme could not open this image."
            alert.informativeText = item.url.lastPathComponent
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let controller = EditorController(item: item, source: source)
        let editor = EditorWindow(controller: controller) { windows[item.id] = nil }
        windows[item.id] = editor
    }
}

/// Owns the window, its toolbar and its keyboard shortcuts for one capture.
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

        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let imageSize = CGSize(width: controller.source.size.width / controller.unit, height: controller.source.size.height / controller.unit)
        let size = CGSize(width: min(max(imageSize.width + 140, 1020), visible.width * 0.92),
                          height: min(max(imageSize.height + 52 + 140, 640), visible.height * 0.9))

        window = WindowPresenter.shared.show("editor-\(controller.item.id.uuidString)",
                                             title: controller.item.url.lastPathComponent,
                                             size: size,
                                             style: [.titled, .closable, .miniaturizable, .resizable],
                                             transparentTitlebar: false) {
            EditorRootView(c: controller)
        }
        super.init()

        (window.contentView as? NSHostingView<EditorRootView>)?.sizingOptions = []
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
        window.center()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
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

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        guard event.window === window else { return false }
        let typing = window.firstResponder is NSText
        if event.keyCode == 49, !typing, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            controller.canvas?.spaceDown = event.type == .keyDown
            return true
        }
        if event.type == .keyUp { return false }
        return controller.handleKeyDown(event)
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
