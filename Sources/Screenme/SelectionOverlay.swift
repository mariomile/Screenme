import AppKit
import ScreenCaptureKit

/// Full-screen picker: drag to select an area, click to pick the highlighted window, Esc to cancel.
@MainActor
final class SelectionOverlay {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureTarget?) -> Void)?
    /// On-screen windows, front to back, with frames in global Cocoa coordinates.
    private let windows: [(SCWindow, CGRect)]

    private init(windows: [(SCWindow, CGRect)]) {
        self.windows = windows
    }

    nonisolated static func make() async throws -> SelectionOverlay {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // CGWindowList is ordered front to back; ScreenCaptureKit is not.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ordered: [(SCWindow, CGRect)] = info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  window.windowLayer == 0,
                  window.owningApplication?.processID != ownPID,
                  window.frame.width > 40, window.frame.height > 40 else { return nil }
            let frame = CGRect(x: window.frame.minX, y: CaptureTarget.primaryHeight - window.frame.maxY,
                               width: window.frame.width, height: window.frame.height)
            return (window, frame)
        }
        return await MainActor.run { SelectionOverlay(windows: ordered) }
    }

    func begin(_ completion: @escaping (CaptureTarget?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setFrame(screen.frame, display: false)
            let view = SelectionView(screen: screen, overlay: self)
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
        refreshAll()
    }

    func window(at point: CGPoint) -> (SCWindow, CGRect)? {
        windows.first { $0.1.contains(point) }
    }

    func refreshAll() {
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    func finish(_ target: CaptureTarget?) {
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        let completion = completion
        self.completion = nil
        completion?(target)
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private let screen: NSScreen
    private unowned let overlay: SelectionOverlay
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var hovered: CGRect?

    init(screen: NSScreen, overlay: SelectionOverlay) {
        self.screen = screen
        self.overlay = overlay
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return rect.width >= 4 || rect.height >= 4 ? rect.intersection(screen.frame) : nil
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = overlay.window(at: NSEvent.mouseLocation)?.1
        overlay.refreshAll()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = NSEvent.mouseLocation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = selection {
            overlay.finish(.area(rect.integral, screen))
        } else if let (window, _) = overlay.window(at: NSEvent.mouseLocation) {
            overlay.finish(.window(window))
        } else {
            dragStart = nil
            dragCurrent = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay.finish(nil) } // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        let toLocal = { (rect: CGRect) in rect.offsetBy(dx: -self.screen.frame.minX, dy: -self.screen.frame.minY) }
        let hole: CGRect? = selection.map(toLocal) ?? (dragStart == nil ? hovered.map(toLocal) : nil)

        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let hole else { return }
        NSColor.clear.setFill()
        hole.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        if let selection {
            let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let origin = CGPoint(x: hole.maxX - size.width - 6, y: max(hole.minY - size.height - 6, 4))
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -2), xRadius: 4, yRadius: 4).fill()
            label.draw(at: origin, withAttributes: attributes)
        }
    }
}
