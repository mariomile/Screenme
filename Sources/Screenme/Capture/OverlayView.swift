import AppKit
import QuartzCore

/// One borderless panel per display. It never draws anything itself: `OverlayView` is layer based.
final class OverlayPanel: FloatingPanel {
    init(screen: NSScreen) {
        super.init(frame: screen.frame, level: .screenSaver, canBeKey: true, hasShadow: false,
                   collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
    }
    /// Keep the panel over the menu bar instead of letting AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum PointerStyle: Equatable {
    case full               // lines across the whole screen
    case small              // a short precise cross
    case glyph(String)      // SF Symbol in a round badge (window mode)
}

struct LoupeInfo {
    var coordinates: String
    var size: String?
}

/// Everything a view needs to draw one frame. Rects and points are global Cocoa coordinates.
struct OverlayState {
    var pointer: CGPoint?
    var pointerStyle: PointerStyle = .small
    var selection: CGRect?
    var windowRect: CGRect?
    var windowLabel: String?
    var loupe: LoupeInfo?
    var hintVisible = true
}

/// The picker for one display. Moving the mouse only changes frames of existing layers:
/// nothing is redrawn, so it stays smooth on large retina screens.
final class OverlayView: NSView {
    let screen: NSScreen
    private let scale: CGFloat

    /// Pixels of this display, for the magnifier. Set once the snapshot has arrived.
    var source: CGImage? { didSet { lastLoupeCenter = nil } }

    private let dim: [CALayer] = (0..<4).map { _ in
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.36).cgColor
        return layer
    }
    private let windowTint = CALayer()
    private let border = CALayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private let lineOutline = [CALayer(), CALayer()]
    private let lineCore = [CALayer(), CALayer()]
    private let glyphLayer = CALayer()
    private let sizePill: Pill
    private let windowPill: Pill
    private let loupe: Loupe
    private let hintView = NSVisualEffectView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var hintShown = false
    private var glyphName: String?
    private var lastLoupeCenter: (Int, Int)?
    private static let blank = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(screen: NSScreen, backdrop: CGImage?) {
        self.screen = screen
        scale = screen.backingScaleFactor
        sizePill = Pill(scale: scale, fontSize: 11.5)
        windowPill = Pill(scale: scale, fontSize: 13)
        loupe = Loupe(scale: scale)
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true
        root.contentsScale = scale

        if let backdrop {
            let layer = CALayer()
            layer.frame = bounds
            layer.contents = backdrop
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            root.addSublayer(layer)
        }
        dim.forEach { root.addSublayer($0) }

        let accent = NSColor.controlAccentColor
        windowTint.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        windowTint.borderColor = accent.cgColor
        windowTint.borderWidth = 2
        windowTint.cornerRadius = 10
        windowTint.isHidden = true
        root.addSublayer(windowTint)

        border.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        border.borderWidth = 1
        border.shadowColor = NSColor.black.cgColor
        border.shadowOpacity = 0.45
        border.shadowRadius = 1.5
        border.shadowOffset = .zero
        border.isHidden = true
        root.addSublayer(border)

        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
            handle.borderWidth = 1
            handle.cornerRadius = 2
            handle.isHidden = true
            root.addSublayer(handle)
        }

        for layer in lineOutline {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            layer.isHidden = true
            root.addSublayer(layer)
        }
        for layer in lineCore {
            layer.backgroundColor = NSColor.white.cgColor
            layer.isHidden = true
            root.addSublayer(layer)
        }

        glyphLayer.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        glyphLayer.contentsScale = scale
        glyphLayer.shadowColor = NSColor.black.cgColor
        glyphLayer.shadowOpacity = 0.35
        glyphLayer.shadowRadius = 4
        glyphLayer.shadowOffset = CGSize(width: 0, height: -1)
        glyphLayer.isHidden = true
        root.addSublayer(glyphLayer)

        sizePill.layer.isHidden = true
        windowPill.layer.isHidden = true
        loupe.layer.isHidden = true
        root.addSublayer(sizePill.layer)
        root.addSublayer(windowPill.layer)
        root.addSublayer(loupe.layer)

        hintView.material = .hudWindow
        hintView.blendingMode = .behindWindow
        hintView.state = .active
        hintView.appearance = NSAppearance(named: .vibrantDark)
        hintView.wantsLayer = true
        hintView.layer?.masksToBounds = true
        hintView.layer?.borderWidth = 0.5
        hintView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        hintView.alphaValue = 0
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.isEditable = false
        hintLabel.lineBreakMode = .byClipping
        hintView.addSubview(hintLabel)
        addSubview(hintView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The system cursor is hidden, but if it ever shows it must be invisible.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blank)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    // MARK: Hint

    func setHint(_ text: NSAttributedString) {
        hintLabel.attributedStringValue = text
        let size = text.size()
        let width = ceil(size.width) + 40, height: CGFloat = 36
        let top = screen.visibleFrame.maxY - screen.frame.minY - 14 - height
        hintView.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
        hintView.layer?.cornerRadius = height / 2
        hintLabel.frame = CGRect(x: 20, y: ((height - ceil(size.height)) / 2).rounded(), width: ceil(size.width) + 2, height: ceil(size.height))
    }

    private func showHint(_ visible: Bool) {
        guard visible != hintShown else { return }
        hintShown = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.18 : 0.1
            hintView.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Drawing

    func apply(_ state: OverlayState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var hole = (state.selection ?? state.windowRect).map(local)?.intersection(bounds)
        if let rect = hole, rect.isNull || rect.width < 1 || rect.height < 1 { hole = nil }
        layoutDim(around: hole)

        let isSelection = state.selection != nil && hole != nil
        layoutSelection(hole, isSelection: isSelection, size: state.selection?.size)
        layoutWindow(hole, isSelection: isSelection, label: state.windowLabel)
        layoutPointer(state)
        showHint(state.hintVisible)
    }

    private func layoutDim(around hole: CGRect?) {
        let b = bounds
        guard let h = hole else {
            dim[0].frame = b
            for index in 1..<4 { dim[index].frame = .zero }
            return
        }
        dim[0].frame = CGRect(x: 0, y: h.maxY, width: b.width, height: max(0, b.height - h.maxY))
        dim[1].frame = CGRect(x: 0, y: 0, width: b.width, height: h.minY)
        dim[2].frame = CGRect(x: 0, y: h.minY, width: h.minX, height: h.height)
        dim[3].frame = CGRect(x: h.maxX, y: h.minY, width: max(0, b.width - h.maxX), height: h.height)
    }

    private func layoutSelection(_ hole: CGRect?, isSelection: Bool, size: CGSize?) {
        border.isHidden = !isSelection
        handles.forEach { $0.isHidden = !isSelection }
        sizePill.layer.isHidden = !isSelection
        guard isSelection, let h = hole, let size else { return }

        border.frame = h
        let corners = [CGPoint(x: h.minX, y: h.minY), CGPoint(x: h.maxX, y: h.minY),
                       CGPoint(x: h.minX, y: h.maxY), CGPoint(x: h.maxX, y: h.maxY)]
        for (handle, corner) in zip(handles, corners) { handle.position = corner }

        sizePill.set("\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
        let pill = sizePill.size
        var y = h.minY - 10 - pill.height
        if y < 6 {
            y = h.maxY + 10
            if y + pill.height > bounds.maxY - 6 { y = h.minY + 10 }
        }
        let x = min(max(h.midX - pill.width / 2, 6), bounds.maxX - pill.width - 6)
        sizePill.layer.frame = CGRect(x: x.rounded(), y: y.rounded(), width: pill.width, height: pill.height)
    }

    private func layoutWindow(_ hole: CGRect?, isSelection: Bool, label: String?) {
        let showTint = hole != nil && !isSelection
        windowTint.isHidden = !showTint
        windowPill.layer.isHidden = !(showTint && label != nil)
        guard showTint, let h = hole else { return }
        windowTint.frame = h
        guard let label else { return }
        windowPill.set(label)
        let pill = windowPill.size
        let x = min(max(h.midX - pill.width / 2, 6), bounds.maxX - pill.width - 6)
        windowPill.layer.frame = CGRect(x: x.rounded(), y: (h.midY - pill.height / 2).rounded(), width: pill.width, height: pill.height)
    }

    private func layoutPointer(_ state: OverlayState) {
        guard let pointer = state.pointer else {
            lineOutline.forEach { $0.isHidden = true }
            lineCore.forEach { $0.isHidden = true }
            glyphLayer.isHidden = true
            loupe.layer.isHidden = true
            return
        }
        let p = CGPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)

        if case .glyph(let name) = state.pointerStyle {
            lineOutline.forEach { $0.isHidden = true }
            lineCore.forEach { $0.isHidden = true }
            if name != glyphName {
                glyphName = name
                glyphLayer.contents = glyphImage(name)
            }
            glyphLayer.isHidden = false
            glyphLayer.position = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        } else {
            glyphLayer.isHidden = true
            // Snap to the device pixel under the pointer so the lines pass through the magnifier's center pixel.
            let pixel = 1 / scale
            let column = floor(p.x * scale)
            let row = floor((bounds.height - p.y) * scale)
            let pixelX = column / scale
            let pixelY = bounds.height - (row + 1) / scale
            // Full-screen lines are one device pixel wide; the short cross is a full point so it stays easy to see.
            let full = state.pointerStyle == .full
            let thickness = full ? pixel : max(1, pixel)
            let x = pixelX + pixel / 2 - thickness / 2
            let y = pixelY + pixel / 2 - thickness / 2
            let horizontal: (CGFloat, CGFloat) = full ? (0, bounds.width) : (x - 9, 19 + thickness)
            let vertical: (CGFloat, CGFloat) = full ? (0, bounds.height) : (y - 9, 19 + thickness)
            let edge = pixel
            lineCore[0].frame = CGRect(x: horizontal.0, y: y, width: horizontal.1, height: thickness)
            lineOutline[0].frame = CGRect(x: horizontal.0 - edge, y: y - edge, width: horizontal.1 + 2 * edge, height: thickness + 2 * edge)
            lineCore[1].frame = CGRect(x: x, y: vertical.0, width: thickness, height: vertical.1)
            lineOutline[1].frame = CGRect(x: x - edge, y: vertical.0 - edge, width: thickness + 2 * edge, height: vertical.1 + 2 * edge)
            lineOutline.forEach { $0.isHidden = false }
            lineCore.forEach { $0.isHidden = false }
        }

        guard let info = state.loupe, let source else {
            loupe.layer.isHidden = true
            return
        }
        let cx = Int(floor(p.x * CGFloat(source.width) / bounds.width))
        let cy = Int(floor((bounds.height - p.y) * CGFloat(source.height) / bounds.height))
        var sample: CGImage?
        if lastLoupeCenter?.0 != cx || lastLoupeCenter?.1 != cy || loupe.layer.isHidden {
            lastLoupeCenter = (cx, cy)
            sample = Loupe.sample(source, centerX: cx, centerY: cy)
        }
        loupe.update(sample: sample, coordinates: info.coordinates, size: info.size)

        let block = loupe.blockSize
        var x = p.x + 28
        if x + block.width > bounds.maxX - 8 { x = p.x - 28 - block.width }
        var y = p.y - 28 - block.height
        if y < 8 { y = p.y + 28 }
        x = min(max(x, 8), bounds.maxX - block.width - 8)
        y = min(max(y, 8), bounds.maxY - block.height - 8)
        loupe.layer.frame = CGRect(x: x.rounded(), y: y.rounded(), width: block.width, height: block.height)
        loupe.layer.isHidden = false
    }

    // MARK: Glyph

    private func glyphImage(_ name: String) -> CGImage? {
        let side: CGFloat = 28
        let accent = NSColor.controlAccentColor
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            accent.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
        var proposed = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}

// MARK: - Pill

/// A small dark label that sits on a layer. The text layer is laid out once per text change.
final class Pill {
    let layer = CALayer()
    private let textLayer = CATextLayer()
    private let font: NSFont
    private let padding: CGFloat = 9
    private let height: CGFloat
    private let lineHeight: CGFloat
    private var current = ""
    private(set) var size = CGSize.zero

    init(scale: CGFloat, fontSize: CGFloat) {
        font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        lineHeight = ceil(font.ascender - font.descender)
        height = lineHeight + 9
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        layer.cornerRadius = height / 2
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        textLayer.contentsScale = scale
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        layer.addSublayer(textLayer)
    }

    func set(_ text: String) {
        guard text != current else { return }
        current = text
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = ceil(attributed.size().width)
        textLayer.string = attributed
        textLayer.frame = CGRect(x: padding, y: ((height - lineHeight) / 2).rounded(), width: width + 2, height: lineHeight)
        size = CGSize(width: width + padding * 2, height: height)
        layer.bounds = CGRect(origin: .zero, size: size)
    }
}

// MARK: - Loupe

/// The magnifier: 15 x 15 screen pixels blown up 9x with a pixel grid, the center pixel marked,
/// and the cursor coordinates underneath.
final class Loupe {
    static let cells = 15
    static let cell: CGFloat = 9
    private static let inset: CGFloat = 2.5
    private static let side = CGFloat(cells) * cell + inset * 2
    private static let radius: CGFloat = 16

    let layer = CALayer()
    private let frameLayer = CALayer()
    private let host = CALayer()
    private let image = CALayer()
    private let grid = CAShapeLayer()
    private let centerOuter = CALayer()
    private let centerInner = CALayer()
    private let coordinates: Pill
    private let size: Pill
    private var showsSize = false

    init(scale: CGFloat) {
        coordinates = Pill(scale: scale, fontSize: 11.5)
        size = Pill(scale: scale, fontSize: 11.5)
        let side = Self.side

        frameLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        frameLayer.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        frameLayer.cornerRadius = Self.radius
        frameLayer.borderWidth = Self.inset
        frameLayer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.4
        frameLayer.shadowRadius = 10
        frameLayer.shadowOffset = CGSize(width: 0, height: -3)
        frameLayer.shadowPath = CGPath(roundedRect: frameLayer.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)

        host.frame = CGRect(x: Self.inset, y: Self.inset, width: side - Self.inset * 2, height: side - Self.inset * 2)
        host.cornerRadius = Self.radius - Self.inset
        host.masksToBounds = true

        image.frame = host.bounds
        image.magnificationFilter = .nearest
        image.minificationFilter = .nearest
        image.contentsGravity = .resize

        let path = CGMutablePath()
        let extent = CGFloat(Self.cells) * Self.cell
        for index in 1..<Self.cells {
            let offset = CGFloat(index) * Self.cell
            path.move(to: CGPoint(x: offset, y: 0)); path.addLine(to: CGPoint(x: offset, y: extent))
            path.move(to: CGPoint(x: 0, y: offset)); path.addLine(to: CGPoint(x: extent, y: offset))
        }
        grid.frame = host.bounds
        grid.path = path
        grid.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
        grid.lineWidth = 0.5

        let middle = CGFloat(Self.cells / 2) * Self.cell
        centerInner.frame = CGRect(x: middle, y: middle, width: Self.cell, height: Self.cell)
        centerInner.borderWidth = 1.5
        centerInner.borderColor = NSColor.white.cgColor
        centerOuter.frame = centerInner.frame.insetBy(dx: -1, dy: -1)
        centerOuter.borderWidth = 1
        centerOuter.borderColor = NSColor.black.withAlphaComponent(0.8).cgColor

        host.addSublayer(image)
        host.addSublayer(grid)
        host.addSublayer(centerOuter)
        host.addSublayer(centerInner)
        frameLayer.addSublayer(host)
        layer.addSublayer(frameLayer)
        layer.addSublayer(coordinates.layer)
        layer.addSublayer(size.layer)
    }

    /// Size of the whole block (loupe plus captions) for the current captions.
    var blockSize: CGSize {
        let captions = coordinates.size.height + (showsSize ? size.size.height + 4 : 0)
        return CGSize(width: Self.side, height: Self.side + 8 + captions)
    }

    func update(sample: CGImage?, coordinates text: String, size sizeText: String?) {
        if let sample { image.contents = sample }
        coordinates.set(text)
        showsSize = sizeText != nil
        size.layer.isHidden = !showsSize
        if let sizeText { size.set(sizeText) }

        let block = blockSize
        layer.bounds = CGRect(origin: .zero, size: block)
        frameLayer.position = CGPoint(x: Self.side / 2, y: block.height - Self.side / 2)
        let coordinatesY = frameLayer.frame.minY - 8 - coordinates.size.height
        coordinates.layer.frame = CGRect(x: ((Self.side - coordinates.size.width) / 2).rounded(), y: coordinatesY.rounded(),
                                         width: coordinates.size.width, height: coordinates.size.height)
        if showsSize {
            let y = coordinatesY - 4 - size.size.height
            size.layer.frame = CGRect(x: ((Self.side - size.size.width) / 2).rounded(), y: y.rounded(),
                                      width: size.size.width, height: size.size.height)
        }
    }

    /// The `cells` x `cells` pixels around (centerX, centerY), in image pixel coordinates (top-left origin).
    /// Pixels outside the image stay dark.
    static func sample(_ image: CGImage, centerX: Int, centerY: Int) -> CGImage? {
        let n = cells
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = image.colorSpace.flatMap {
            CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info)
        } ?? CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        guard let context else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: n, height: n))

        let wanted = CGRect(x: centerX - n / 2, y: centerY - n / 2, width: n, height: n)
        let visible = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isNull, let part = image.cropping(to: visible) {
            // Image rows run top to bottom, the bitmap context's run bottom to top.
            context.draw(part, in: CGRect(x: visible.minX - wanted.minX,
                                          y: CGFloat(n) - (visible.minY - wanted.minY) - visible.height,
                                          width: visible.width, height: visible.height))
        }
        return context.makeImage()
    }
}
