import AppKit
import SwiftUI

extension Pref {
    static let liveDrawTool = PrefKey(name: "liveDrawTool", defaultValue: LiveDrawTool.pen)
    static let liveDrawColor = PrefKey(name: "liveDrawColor", defaultValue: LiveDrawColor.red)
    static let liveDrawKeep = PrefKey(name: "liveDrawKeep", defaultValue: false)
}

/// Each live drawing tool is an editor annotation kind, drawn by `EditorRenderer`, so live drawings look like
/// annotations. A pin is the editor's numbered counter.
extension LiveDrawTool {
    var kind: ToolKind { self == .pin ? .counter : ToolKind(rawValue: rawValue)! }
    var title: String { self == .pin ? "Pin" : kind.traits.title }
    var symbol: String { self == .pin ? "mappin" : kind.traits.symbol }

    var help: String {
        switch self {
        case .pen: "Pen\nDraw freehand on the screen."
        case .arrow: "Arrow\nDrag to point at something."
        case .rectangle: "Rectangle\nDrag to frame an area."
        case .highlighter: "Highlighter\nMark text or an area with a translucent marker."
        case .pin: "Pin  ⇧-click\nClick to drop a numbered red pin. Pins stay until the recording ends and show in the report as pin 1, pin 2… ⇧-click drops one with any tool."
        }
    }
}

extension LiveDrawColor {
    var rgba: RGBA {
        switch self {
        case .red: Palette.red
        case .yellow: Palette.yellow
        case .green: Palette.green
        case .blue: Palette.blue
        }
    }
}

/// Draw mode while recording: whether it is on, and the tool, color and Keep setting, remembered in Prefs.
@MainActor
final class LiveDrawing: ObservableObject {
    @Published var isOn = false
    @Published var tool = Prefs[Pref.liveDrawTool] { didSet { Prefs[Pref.liveDrawTool] = tool } }
    @Published var color = Prefs[Pref.liveDrawColor] { didSet { Prefs[Pref.liveDrawColor] = color } }
    /// Drawings stay until Clear. Off, each fades out a few seconds after it is finished.
    @Published var keep = Prefs[Pref.liveDrawKeep] {
        didSet {
            Prefs[Pref.liveDrawKeep] = keep
            if !keep { canvas?.fadeAll() }
        }
    }

    weak var canvas: DrawingCanvas?
    /// A drawing was finished: its tool, color, bounding box and, for an arrow, its tip, in the canvas (top-left origin).
    var onDrawing: (LiveDrawTool, LiveDrawColor, CGRect, CGPoint?) -> Void = { _, _, _, _ in }
    /// A pin was dropped: its number and where, in the canvas (top-left origin).
    var onPin: (Int, CGPoint) -> Void = { _, _ in }
    /// Pins dropped in this take: the next one is `pins + 1`.
    var pins = 0

    /// Clear in the palette: every drawing goes, the pins stay.
    func clear() { canvas?.clear() }

    /// What a new drawing looks like: the editor's style for the kind, in the chosen color.
    var style: ToolStyle {
        var style = tool.kind.traits.style
        style.color = color.rgba
        // The editor's highlighter multiplies onto the image; over a transparent overlay it would cover the text instead.
        if tool == .highlighter { style.opacity = 0.35 }
        return style
    }
}

/// The drawing surface inside the recording overlay. It takes the mouse only in draw mode; otherwise the
/// overlay ignores the mouse and clicks reach the apps below.
@MainActor
final class DrawingCanvas: NSView {
    static let fadeDelay: TimeInterval = 3

    private let drawing: LiveDrawing
    private var current: AnnotationView?
    private var start = CGPoint.zero
    private var currentTool = LiveDrawTool.pen

    init(frame: CGRect, drawing: LiveDrawing) {
        self.drawing = drawing
        super.init(frame: frame)
        wantsLayer = true
        drawing.canvas = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { drawing.isOn ? super.hitTest(point) : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if drawing.isOn { NSCursor.crosshair.set() } }
    override func mouseEntered(with event: NSEvent) { if drawing.isOn { NSCursor.crosshair.set() } }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Drawing

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if drawing.tool == .pin || event.modifierFlags.contains(.shift) { return dropPin(at: point) }
        start = point
        currentTool = drawing.tool
        let view = AnnotationView(frame: bounds, annotation: Annotation(kind: currentTool.kind, style: drawing.style, at: point))
        addSubview(view)
        current = view
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch current.annotation.shape {
        case .stroke(let points): current.annotation.shape = .stroke(points + [point])
        case .segment(let p0, _, let bend): current.annotation.shape = .segment(p0: p0, p1: point, bend: bend)
        case .box: current.annotation.shape = .box(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                                          width: abs(point.x - start.x), height: abs(point.y - start.y)))
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let view = current else { return }
        current = nil
        let box = view.annotation.bounds(unit: 1)
        // A click without a drag draws nothing worth keeping.
        guard max(box.width, box.height) >= 6 else { return view.removeFromSuperview() }
        var tip: CGPoint?
        if case .segment(_, let p1, _) = view.annotation.shape { tip = p1 }
        drawing.onDrawing(currentTool, drawing.color, box.intersection(bounds), tip)
        // A finished drawing keeps only its own area (plus room for the arrow's shadow), not a full-screen layer.
        view.frame = box.insetBy(dx: -12, dy: -12).integral.intersection(bounds)
        if !drawing.keep { fade(view, after: Self.fadeDelay) }
    }

    /// A numbered red pin, which stays until the recording ends: neither fading nor Clear removes it.
    private func dropPin(at point: CGPoint) {
        drawing.pins += 1
        var style = LiveDrawTool.pin.kind.traits.style
        style.color = LiveDrawColor.red.rgba
        let view = AnnotationView(frame: bounds, annotation: Annotation(kind: .counter, style: style, at: point), number: drawing.pins)
        addSubview(view)
        view.frame = view.annotation.bounds(unit: 1).insetBy(dx: -12, dy: -12).integral.intersection(bounds)
        drawing.onPin(drawing.pins, point)
    }

    /// Fades every finished drawing out, after the usual delay. Keep was turned off.
    func fadeAll() {
        for case let view as AnnotationView in subviews where view !== current && !view.isPin { fade(view, after: Self.fadeDelay) }
    }

    /// Removes the drawings, and the pins too with `pins` (a restart, which starts the numbers again).
    func clear(pins: Bool = false) {
        for case let view as AnnotationView in subviews where view !== current && (pins || !view.isPin) { view.removeFromSuperview() }
        if pins { drawing.pins = 0 }
    }

    private func fade(_ view: AnnotationView, after delay: TimeInterval) {
        Task { [weak self, weak view] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let view, view.superview === self, !self.drawing.keep, !view.isPin else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                view.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { view.removeFromSuperview() }
            }
        }
    }
}

/// One drawing, painted by the editor's renderer in points.
@MainActor
private final class AnnotationView: NSView {
    var annotation: Annotation { didSet { needsDisplay = true } }
    /// The number a pin shows; nil for a drawing.
    let number: Int?
    var isPin: Bool { number != nil }

    init(frame: CGRect, annotation: Annotation, number: Int? = nil) {
        self.annotation = annotation
        self.number = number
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The annotation is in canvas coordinates.
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        EditorRenderer.draw(annotation, number: number ?? 1, unit: 1, ctx: ctx, baseScale: window?.backingScaleFactor ?? 2)
    }
}

// MARK: - Palette

/// The small floating palette of draw mode: tools, colors, Keep, Clear and Done. A Screenme window like the
/// control bar, so it is left out of the recording.
@MainActor
final class DrawPalette {
    private let panel: FloatingPanel

    /// Above `bar` (the recording controls), or below it when there is no room.
    init(drawing: LiveDrawing, near bar: CGRect, done: @escaping () -> Void) {
        let view = NSHostingView(rootView: PaletteView(drawing: drawing, done: done))
        let size = view.fittingSize
        let screen = NSScreen.at(CGPoint(x: bar.midX, y: bar.midY))
        var y = bar.maxY + 8
        if y + size.height > screen.visibleFrame.maxY - 8 { y = bar.minY - 8 - size.height }
        let x = min(max(bar.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel = FloatingPanel(frame: CGRect(x: x, y: y, width: size.width, height: size.height), level: .popUpMenu)
        panel.isMovableByWindowBackground = true
        panel.contentView = view
    }

    func show() { panel.present() }
    func close() { panel.dismiss() }

    private struct PaletteView: View {
        @ObservedObject var drawing: LiveDrawing
        let done: () -> Void

        var body: some View {
            HStack(spacing: 2) {
                ForEach(LiveDrawTool.allCases) { tool in
                    SymbolButton(symbol: tool.symbol, help: tool.help, style: .bar(active: drawing.tool == tool)) { drawing.tool = tool }
                }
                divider
                ForEach(LiveDrawColor.allCases) { color in
                    Button { drawing.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color.rgba.nsColor))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white, lineWidth: drawing.color == color ? 2.5 : 0))
                            .frame(width: 28, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(color.title)\nDraws in \(color.rawValue).")
                }
                divider
                SymbolButton(symbol: drawing.keep ? "pin.fill" : "pin",
                             help: drawing.keep ? "Keep Drawings: on\nDrawings stay on screen until you clear them."
                                                : "Keep Drawings: off\nEach drawing fades out 3 seconds after you finish it. Turn on to keep them until Clear.",
                             style: .bar(active: drawing.keep)) {
                    drawing.keep.toggle()
                }
                SymbolButton(symbol: "eraser", help: "Clear\nRemoves every drawing from the screen. Pins stay until the recording ends.", style: .bar()) { drawing.clear() }
                SymbolButton(symbol: "checkmark", help: "Done  ⌥⌘D or Esc\nLeaves draw mode; clicks go to your apps again.", style: .bar(), action: done)
            }
            .padding(6)
            .background(VisualEffectBackground().clipShape(Capsule()))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
            .fixedSize()
        }

        private var divider: some View {
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 20).padding(.horizontal, 4)
        }
    }
}
