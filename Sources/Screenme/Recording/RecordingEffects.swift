import AppKit
import QuartzCore

/// A transparent, click-through window over the recorded area that draws click highlights and
/// pressed shortcuts. It is one of the few Screenme windows that is part of the recording.
@MainActor
final class RecordingEffects {
    let panel: FloatingPanel
    private let root: NSView
    private let highlightClicks: Bool
    private let showKeystrokes: Bool

    private var monitors: [Any] = []
    private var pressLayer: CALayer?
    private let keyPill = KeyPillView()
    private var keyHistory: [(String, Date)] = []
    private var keyHideTask: Task<Void, Never>?

    init(frame: CGRect, highlightClicks: Bool, showKeystrokes: Bool) {
        self.highlightClicks = highlightClicks
        self.showKeystrokes = showKeystrokes
        panel = FloatingPanel(frame: frame, level: .popUpMenu, hasShadow: false)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        panel.contentView = root

        keyPill.alphaValue = 0
        root.addSubview(keyPill)
    }

    /// Puts the window on screen so ScreenCaptureKit can find it. Call before building the filter.
    func show() {
        panel.orderFrontRegardless()
    }

    func start() {
        if highlightClicks {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                               .rightMouseDown, .rightMouseUp, .rightMouseDragged]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                let type = event.type
                MainActor.assumeIsolated { self?.handleMouse(type) }
            }) { monitors.append(monitor) }
        }
        if showKeystrokes, Accessibility.trusted {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                let label = Self.label(for: event)
                MainActor.assumeIsolated { if let label { self?.showKey(label) } }
            }) { monitors.append(monitor) }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        keyHideTask?.cancel()
        panel.orderOut(nil)
    }

    // MARK: Clicks

    private func handleMouse(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x - panel.frame.minX, y: location.y - panel.frame.minY)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            press(at: point, right: type == .rightMouseDown)
        case .leftMouseDragged, .rightMouseDragged:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pressLayer?.position = point
            CATransaction.commit()
        case .leftMouseUp, .rightMouseUp:
            release()
        default:
            break
        }
    }

    private func press(at point: CGPoint, right: Bool) {
        release()
        guard root.bounds.insetBy(dx: -30, dy: -30).contains(point), let host = root.layer else { return }
        let radius: CGFloat = 26
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.position = point
        layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        let tint = right ? NSColor.systemBlue : NSColor.systemYellow
        layer.fillColor = tint.withAlphaComponent(0.38).cgColor
        layer.strokeColor = tint.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.5
        host.addSublayer(layer)
        pressLayer = layer

        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1
        grow.damping = 12
        grow.stiffness = 320
        grow.mass = 0.7
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "press")
    }

    private func release() {
        guard let layer = pressLayer else { return }
        pressLayer = nil
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.32
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { layer.removeFromSuperlayer() }
    }

    // MARK: Keystrokes

    private func showKey(_ label: String) {
        let now = Date()
        keyHistory.removeAll { now.timeIntervalSince($0.1) > 1.2 }
        keyHistory.append((label, now))
        if keyHistory.count > 3 { keyHistory.removeFirst() }
        keyPill.text = keyHistory.map(\.0).joined(separator: "   ")
        let size = keyPill.fittingSize
        keyPill.frame = CGRect(x: (root.bounds.width - size.width) / 2, y: min(36, max(8, root.bounds.height * 0.08)),
                               width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            keyPill.animator().alphaValue = 1
        }
        keyHideTask?.cancel()
        keyHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.3
            self.keyPill.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
            self.keyHistory.removeAll()
        }
    }

    /// "⌘⇧4", "⌃⌥Space", "Return". Plain letters are not shown: only shortcuts and special keys.
    nonisolated static func label(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let special: [UInt16: String] = [
            36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12",
        ]
        let hasCommandLike = !flags.intersection([.command, .option, .control]).isEmpty
        let name: String
        if let known = special[event.keyCode] {
            name = known
        } else if hasCommandLike, let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            name = characters.uppercased()
        } else {
            return nil
        }
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix + name
    }
}

/// The dark pill that shows the keys being pressed.
private final class KeyPillView: NSView {
    var text = "" {
        didSet { label.stringValue = text; invalidateIntrinsicContentSize(); layoutSubtreeIfNeeded() }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isBordered = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let size = label.attributedStringValue.size()
        return NSSize(width: ceil(size.width) + 36, height: ceil(size.height) + 18)
    }

    override func layout() {
        super.layout()
        let size = label.attributedStringValue.size()
        label.frame = CGRect(x: 18, y: (bounds.height - size.height) / 2, width: bounds.width - 36, height: ceil(size.height))
    }
}

// MARK: - Outlines

/// Dims everything except the area before recording starts, with the size of the area on top.
@MainActor
final class AreaDimmer {
    private let panel: FloatingPanel

    init(area: CGRect, screen: NSScreen) {
        panel = FloatingPanel(frame: screen.frame, level: .floating, hasShadow: false)
        panel.ignoresMouseEvents = true
        panel.contentView = DimView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                    hole: area.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
    }

    func show() { panel.present() }
    func close() { panel.dismiss() }

    private final class DimView: NSView {
        private let hole: CGRect

        init(frame: CGRect, hole: CGRect) {
            self.hole = hole
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.38).setFill()
            bounds.fill()
            NSColor.clear.setFill()
            hole.fill(using: .copy)

            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

            let label = "\(Int(hole.width)) × \(Int(hole.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let pill = CGRect(x: hole.midX - size.width / 2 - 7, y: hole.maxY + 8, width: size.width + 14, height: size.height + 6)
            let placed = pill.maxY > bounds.maxY - 4 ? pill.offsetBy(dx: 0, dy: -(pill.height + 16)) : pill
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: placed, xRadius: placed.height / 2, yRadius: placed.height / 2).fill()
            label.draw(at: CGPoint(x: placed.minX + 7, y: placed.minY + 3), withAttributes: attributes)
        }
    }
}

/// The red frame around the area while recording. Excluded from the capture like every Screenme window.
@MainActor
final class RecordingOutline {
    private let panel: FloatingPanel
    private let border = NSView()

    init(frame: CGRect, insideFrame: Bool) {
        let rect = insideFrame ? frame : frame.insetBy(dx: -3, dy: -3)
        panel = FloatingPanel(frame: rect, level: .statusBar, hasShadow: false)
        panel.ignoresMouseEvents = true
        let content = NSView(frame: CGRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        border.frame = content.bounds
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.95).cgColor
        border.layer?.borderWidth = 2
        border.layer?.cornerRadius = insideFrame ? 0 : 2
        content.addSubview(border)
        panel.contentView = content
    }

    func show() { panel.present() }

    func setPaused(_ paused: Bool) {
        border.layer?.borderColor = (paused ? NSColor.systemOrange : NSColor.systemRed).withAlphaComponent(0.95).cgColor
    }

    func close() { panel.dismiss() }
}
