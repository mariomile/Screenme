import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Measure: a ruler over a frozen picture of the screen under the mouse. Moving shows the width and height
/// of the area of one color under the pointer (edges found by `EdgeScanner`); dragging draws a box and shows
/// its size. A click or ⌘C copies the measurement ("248 × 36"), Esc closes.
@MainActor
enum MeasureOverlay {
    static func run() async throws {
        let screen = NSScreen.underMouse
        let snapshot = await SnapshotLoader.load(screens: [screen], images: true, showsCursor: false)
        guard let image = snapshot.images[screen.displayID] else { throw ScreenmeError.displayNotFound }
        // About 59 MB at 5K: decoded off the main thread, before the ruler shows.
        guard let pixels = await Task.detached(priority: .userInitiated, operation: { PixelBuffer(image) }).value else {
            throw ScreenmeError.displayNotFound
        }
        guard let copied = await MeasureSession(screen: screen, image: image, pixels: pixels).run() else { return }
        Clipboard.copyText(copied)
        Toast.show("Copied \(copied)", symbol: "ruler")
    }
}

/// One run of the ruler: the panel, the pointer, the drag and the way out.
@MainActor
private final class MeasureSession {
    private let screen: NSScreen
    private let pixels: PixelBuffer
    /// Image pixels per point.
    private let scale: CGFloat
    private let panel: OverlayPanel
    private let view: MeasureView

    private var pointer = NSEvent.mouseLocation
    private var spans: EdgeScanner.Spans?
    /// Where a drag started, in view points.
    private var dragStart: CGPoint?
    private var box: CGRect?

    private var previousApp: NSRunningApplication?
    private var eventMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var finished = false
    private var continuation: CheckedContinuation<String?, Never>?

    init(screen: NSScreen, image: CGImage, pixels: PixelBuffer) {
        self.screen = screen
        self.pixels = pixels
        scale = CGFloat(image.width) / screen.frame.width
        panel = OverlayPanel(screen: screen)
        view = MeasureView(screen: screen, backdrop: image)
        panel.contentView = view
    }

    /// The text to copy, or nil when closed with Esc.
    func run() async -> String? {
        previousApp = FocusKeeper.frontmostExternal()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateCursorRects(for: view)
        FocusKeeper.activateSelf()
        install()
        pointerMoved(to: NSEvent.mouseLocation)
        let result = await withCheckedContinuation { self.continuation = $0 }
        let app = previousApp
        Task { await FocusKeeper.restore(app) }
        return result
    }

    private func install() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .keyDown,
        ]) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated { self.handle(box.event) }
            return consumed ? nil : event
        }
        // As in the picker: mouse-moved events do not always reach the panel of an inactive app,
        // so the moves other apps get are followed too.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                let location = NSEvent.mouseLocation
                if location != self.pointer { self.pointerMoved(to: location) }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ result: String?) {
        guard !finished else { return }
        finished = true
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel.orderOut(nil)
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: Events

    private func handle(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            pointerMoved(to: NSEvent.mouseLocation)
        case .leftMouseDown:
            pointerMoved(to: NSEvent.mouseLocation)
            dragStart = local(pointer)
        case .leftMouseUp:
            pointerMoved(to: NSEvent.mouseLocation)
            let dragged = dragStart.map { dragRect(from: $0) }
            dragStart = nil
            if let dragged, dragged.width >= 2 || dragged.height >= 2 {
                box = dragged
                view.update(spans: spanLines(), label: spanLabel(), box: box)
            } else {
                // A click copies what the labels show: the box when there is one, like ⌘C.
                finish(box.map { size($0) } ?? spanText())
            }
        case .rightMouseDown, .otherMouseDown:
            finish(nil)
        case .keyDown:
            if Int(event.keyCode) == kVK_Escape {
                finish(nil)
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
                finish(box.map { size($0) } ?? spanText())
            }
        default:
            return false
        }
        return true
    }

    private func pointerMoved(to location: CGPoint) {
        pointer = location
        let p = local(location)
        let x = Int(floor(p.x * scale)), y = Int(floor((screen.frame.height - p.y) * scale))
        spans = EdgeScanner.spans(in: pixels, x: x, y: y)
        if let dragStart {
            let rect = dragRect(from: dragStart)
            if rect.width >= 2 || rect.height >= 2 { box = rect }
        }
        view.update(spans: spanLines(), label: spanLabel(), box: box)
    }

    // MARK: Geometry

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
    }

    /// A drag from `start` to the pointer, in whole points, kept on the screen.
    private func dragRect(from start: CGPoint) -> CGRect {
        let end = local(pointer)
        let minX = min(start.x, end.x).rounded(), maxX = max(start.x, end.x).rounded()
        let minY = min(start.y, end.y).rounded(), maxY = max(start.y, end.y).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
    }

    /// The horizontal and vertical runs as segments in view points, through the middle of the pointer's pixel.
    private func spanLines() -> MeasureView.Lines? {
        guard let spans else { return nil }
        let height = screen.frame.height
        let rowY = height - (CGFloat(pointerPixelRow(spans)) + 0.5) / scale
        let columnX = (CGFloat(pointerPixelColumn(spans)) + 0.5) / scale
        return MeasureView.Lines(
            horizontal: (CGPoint(x: CGFloat(spans.minX) / scale, y: rowY), CGPoint(x: CGFloat(spans.maxX + 1) / scale, y: rowY)),
            vertical: (CGPoint(x: columnX, y: height - CGFloat(spans.minY) / scale), CGPoint(x: columnX, y: height - CGFloat(spans.maxY + 1) / scale)),
            pointer: local(pointer))
    }

    private func pointerPixelColumn(_ spans: EdgeScanner.Spans) -> Int {
        min(max(Int(floor(local(pointer).x * scale)), spans.minX), spans.maxX)
    }

    private func pointerPixelRow(_ spans: EdgeScanner.Spans) -> Int {
        min(max(Int(floor((screen.frame.height - local(pointer).y) * scale)), spans.minY), spans.maxY)
    }

    private func points(_ pixels: Int) -> Int { Int((CGFloat(pixels) / scale).rounded()) }

    private func spanText() -> String? {
        spans.map { "\(points($0.width)) × \(points($0.height))" }
    }

    private func spanLabel() -> String? {
        spanText().map { $0 + " pt" }
    }

    private func size(_ rect: CGRect) -> String {
        "\(Int(rect.width)) × \(Int(rect.height))"
    }
}

// MARK: - View

/// The frozen screen with the ruler on top. Layer based like the picker: moving only changes paths and frames.
private final class MeasureView: NSView {
    struct Lines {
        var horizontal: (CGPoint, CGPoint)
        var vertical: (CGPoint, CGPoint)
        var pointer: CGPoint
    }

    private let screen: NSScreen
    private let outline = CAShapeLayer()
    private let core = CAShapeLayer()
    private let boxLayer = CALayer()
    private let label: Pill
    private let boxLabel: Pill
    private let hint: Pill

    init(screen: NSScreen, backdrop: CGImage) {
        self.screen = screen
        let scale = screen.backingScaleFactor
        label = Pill(scale: scale, fontSize: 12)
        boxLabel = Pill(scale: scale, fontSize: 12)
        hint = Pill(scale: scale, fontSize: 12)
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true
        root.contentsScale = scale

        let image = CALayer()
        image.frame = bounds
        image.contents = backdrop
        image.contentsScale = scale
        image.contentsGravity = .resize
        root.addSublayer(image)

        let accent = NSColor.controlAccentColor
        boxLayer.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        boxLayer.borderColor = accent.cgColor
        boxLayer.borderWidth = 1
        boxLayer.isHidden = true
        root.addSublayer(boxLayer)

        outline.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        outline.lineWidth = 3
        core.strokeColor = NSColor.systemPink.cgColor
        core.lineWidth = 1
        for layer in [outline, core] {
            layer.fillColor = nil
            layer.contentsScale = scale
            root.addSublayer(layer)
        }

        for pill in [label, boxLabel, hint] {
            pill.layer.isHidden = true
            root.addSublayer(pill.layer)
        }
        hint.set("Move to measure   ·   Drag for a box   ·   Click or ⌘C to copy   ·   Esc to close")
        let top = screen.visibleFrame.maxY - screen.frame.minY - 14 - hint.size.height
        hint.layer.frame = CGRect(x: ((bounds.width - hint.size.width) / 2).rounded(), y: top, width: hint.size.width, height: hint.size.height)
        hint.layer.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func update(spans lines: Lines?, label text: String?, box: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let lines {
            let path = CGMutablePath()
            let tick: CGFloat = 4
            let (left, right) = lines.horizontal
            path.move(to: left); path.addLine(to: right)
            path.move(to: CGPoint(x: left.x, y: left.y - tick)); path.addLine(to: CGPoint(x: left.x, y: left.y + tick))
            path.move(to: CGPoint(x: right.x, y: right.y - tick)); path.addLine(to: CGPoint(x: right.x, y: right.y + tick))
            let (top, bottom) = lines.vertical
            path.move(to: top); path.addLine(to: bottom)
            path.move(to: CGPoint(x: top.x - tick, y: top.y)); path.addLine(to: CGPoint(x: top.x + tick, y: top.y))
            path.move(to: CGPoint(x: bottom.x - tick, y: bottom.y)); path.addLine(to: CGPoint(x: bottom.x + tick, y: bottom.y))
            outline.path = path
            core.path = path
        } else {
            outline.path = nil
            core.path = nil
        }

        label.layer.isHidden = text == nil || lines == nil
        if let text, let lines {
            label.set(text)
            let size = label.size
            var x = lines.pointer.x + 16
            if x + size.width > bounds.maxX - 6 { x = lines.pointer.x - 16 - size.width }
            var y = lines.pointer.y - 16 - size.height
            if y < 6 { y = lines.pointer.y + 16 }
            label.layer.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }

        boxLayer.isHidden = box == nil
        boxLabel.layer.isHidden = box == nil
        if let box {
            boxLayer.frame = box
            boxLabel.set("\(Int(box.width)) × \(Int(box.height)) pt")
            let size = boxLabel.size
            var y = box.minY - 8 - size.height
            if y < 6 { y = box.maxY + 8 }
            let x = min(max(box.midX - size.width / 2, 6), bounds.maxX - size.width - 6)
            boxLabel.layer.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
    }
}
