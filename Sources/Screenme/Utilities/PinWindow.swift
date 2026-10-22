import AppKit

/// Floating, always-on-top screenshots. Pin as many as you like; they follow you across Spaces.
@MainActor
enum PinWindow {
    private static var controllers: [PinWindowController] = []
    private static var lockTimer: Timer?

    /// Pins a capture at full size. Videos pin a frame near the start, GIFs their first frame.
    static func pin(_ item: CaptureItem) {
        Task {
            guard let preview = await Thumbnails.make(for: item, maxPixelSize: nil) else { return }
            show(preview.image, for: item)
        }
    }

    static func unpinAll() {
        controllers.forEach { $0.close(animated: true) }
    }

    static func unlockAll() {
        controllers.forEach { $0.setLocked(false) }
    }

    // MARK: Internal

    fileprivate static var hasLockedPins: Bool { controllers.contains { $0.isLocked } }

    fileprivate static func closed(_ controller: PinWindowController) {
        controllers.removeAll { $0 === controller }
        updateLockTimer()
    }

    /// Locked pins are click-through. Holding Option over one makes it interactive again,
    /// so its menu (with Unlock) stays reachable.
    fileprivate static func updateLockTimer() {
        if hasLockedPins {
            guard lockTimer == nil else { return }
            let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let option = NSEvent.modifierFlags.contains(.option)
                    let mouse = NSEvent.mouseLocation
                    for controller in controllers where controller.isLocked {
                        controller.panel.ignoresMouseEvents = !(option && controller.panel.frame.contains(mouse))
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            lockTimer = timer
        } else {
            lockTimer?.invalidate()
            lockTimer = nil
        }
    }

    private static func show(_ image: CGImage, for item: CaptureItem) {
        let controller = PinWindowController(image: image, item: item, index: controllers.count)
        controllers.append(controller)
        controller.present()
    }
}

// MARK: - Controller

@MainActor
private final class PinWindowController: NSObject {
    let item: CaptureItem
    let panel: PinFloatingPanel
    private let imageView: PinContentView
    private let naturalSize: CGSize
    private(set) var isLocked = false
    private var zoom: CGFloat

    init(image: CGImage, item: CaptureItem, index: Int) {
        self.item = item
        let screen = NSScreen.underMouse
        let scale = screen.backingScaleFactor
        naturalSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // Start at actual size, shrunk to fit 80% of the screen.
        let visible = screen.visibleFrame
        let fit = min(1, visible.width * 0.8 / naturalSize.width, visible.height * 0.8 / naturalSize.height)
        zoom = fit
        let size = CGSize(width: naturalSize.width * fit, height: naturalSize.height * fit)
        let cascade = CGFloat(index % 8) * 28
        let origin = CGPoint(x: visible.midX - size.width / 2 + cascade, y: visible.midY - size.height / 2 - cascade)

        // Not a non-activating panel: a click must activate Screenme, or the pin never gets Esc, ⌘C, ⌘W and the zoom keys.
        // Showing it does not activate anything, so a new pin never takes focus from the user's app.
        panel = PinFloatingPanel(frame: CGRect(origin: origin, size: size), level: .floating, canBeKey: true,
                                 activatesOnClick: true, collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        imageView = PinContentView(image: image, frame: CGRect(origin: .zero, size: size))
        super.init()

        panel.contentView = imageView
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        imageView.controller = self
    }

    // MARK: Lifecycle

    func present() {
        let final = panel.frame
        panel.present(makeKey: true, from: final.insetBy(dx: final.width * 0.03, dy: final.height * 0.03))
        panel.makeFirstResponder(imageView)
    }

    func close(animated: Bool = true) {
        PinWindow.closed(self)
        if animated { panel.dismiss() } else { panel.orderOut(nil) }
    }

    // MARK: Zoom

    /// Scales the window around `anchor` (global screen coordinates), keeping the point under the cursor still.
    func zoom(by factor: CGFloat, anchor: CGPoint? = nil, animated: Bool = false) {
        setZoom(zoom * factor, anchor: anchor, animated: animated)
    }

    func setZoom(_ target: CGFloat, anchor: CGPoint? = nil, animated: Bool = false) {
        let screenSize = NSScreen.underMouse.frame.size
        let minZoom = 48 / min(naturalSize.width, naturalSize.height)
        let maxZoom = min(8, max(screenSize.width, screenSize.height) * 3 / max(naturalSize.width, naturalSize.height))
        let clamped = min(max(target, minZoom), max(maxZoom, minZoom))
        guard abs(clamped - zoom) > 0.0001 else { return }

        let old = panel.frame
        let size = CGSize(width: naturalSize.width * clamped, height: naturalSize.height * clamped)
        let point = anchor ?? CGPoint(x: old.midX, y: old.midY)
        let fx = (point.x - old.minX) / old.width
        let fy = (point.y - old.minY) / old.height
        let frame = CGRect(x: point.x - fx * size.width, y: point.y - fy * size.height, width: size.width, height: size.height)
        zoom = clamped

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        imageView.flashLabel("\(Int((clamped * 100).rounded()))%")
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 { // Esc
            close()
            return true
        }
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "=", "+": zoom(by: 1.15, animated: true)
        case "-": zoom(by: 1 / 1.15, animated: true)
        case "0": setZoom(1, animated: true)
        case "c": perform(.copy)
        case "s": perform(.save)
        case "w": close()
        default: return false
        }
        return true
    }

    // MARK: Menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        CaptureAction.menuItems([.copy, .copyForAI, .copyMarkdown, .copyPath, .save, .edit, .uploadLink, .share], for: item,
                                keys: [.copy: "c", .save: "s"]) { [weak self] in self?.perform($0) }
            .forEach(menu.addItem)
        menu.addItem(.separator())

        let opacity = NSMenu()
        for percent in [100, 75, 50, 25] {
            let entry = entry("\(percent)%", #selector(opacityAction(_:)))
            entry.tag = percent
            entry.state = abs(panel.alphaValue - CGFloat(percent) / 100) < 0.01 ? .on : .off
            opacity.addItem(entry)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacity
        menu.addItem(opacityItem)

        let size = NSMenu()
        size.addItem(entry("Zoom In", #selector(zoomInAction), key: "+"))
        size.addItem(entry("Zoom Out", #selector(zoomOutAction), key: "-"))
        size.addItem(entry("Actual Size", #selector(actualSizeAction), key: "0"))
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = size
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        let lock = entry(isLocked ? "Unlock" : "Lock (click-through)", #selector(lockAction))
        lock.state = isLocked ? .on : .off
        menu.addItem(lock)
        menu.addItem(entry("Close", #selector(closeAction), key: "w"))
        menu.addItem(.separator())
        menu.addItem(entry("Unpin All", #selector(unpinAllAction)))
        if PinWindow.hasLockedPins { menu.addItem(entry("Unlock All Pins", #selector(unlockAllAction))) }
        return menu
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = .command }
        return item
    }

    // MARK: Actions

    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        panel.ignoresMouseEvents = locked
        if locked { Toast.show("Pin locked. Hold \u{2325} over it to unlock.", symbol: "lock.fill", duration: 2.4) }
        PinWindow.updateLockTimer()
    }

    private func perform(_ action: CaptureAction) {
        let item = item
        Task { await action.perform(item) }
    }

    @objc private func opacityAction(_ sender: NSMenuItem) { panel.animator().alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func zoomInAction() { zoom(by: 1.15, animated: true) }
    @objc private func zoomOutAction() { zoom(by: 1 / 1.15, animated: true) }
    @objc private func actualSizeAction() { setZoom(1, animated: true) }
    @objc private func lockAction() { setLocked(!isLocked) }
    @objc private func closeAction() { close() }
    @objc private func unpinAllAction() { PinWindow.unpinAll() }
    @objc private func unlockAllAction() { PinWindow.unlockAll() }
}

// MARK: - Panel

/// Handles a pin's keys once: ⌘ shortcuts in `performKeyEquivalent`, Esc when it reaches the window's `keyDown`
/// (the content view passes keys up the responder chain untouched).
private final class PinFloatingPanel: FloatingPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

// MARK: - Content view

private final class PinContentView: NSView {
    weak var controller: PinWindowController?
    private let closeButton = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let labelBackground = NSView()
    private var labelTask: Task<Void, Never>?

    init(image: CGImage, frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        autoresizingMask = [.width, .height]

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pin")?
            .withSymbolConfiguration(configuration)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.frame = CGRect(x: 8, y: frame.height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.alphaValue = 0
        closeButton.toolTip = "Close\nRemoves this pin from the screen. The capture stays in History."
        addSubview(closeButton)

        labelBackground.wantsLayer = true
        labelBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        labelBackground.layer?.cornerRadius = 8
        labelBackground.alphaValue = 0
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        labelBackground.addSubview(label)
        addSubview(labelBackground)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        refreshBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }

    private func refreshBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; closeButton.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; closeButton.animator().alphaValue = 0 }
    }

    @objc private func closeClicked() { controller?.close() }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller?.close()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.makeMenu() }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let rate: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.06
        controller?.zoom(by: exp(delta * rate), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        controller?.zoom(by: 1 + event.magnification, anchor: NSEvent.mouseLocation)
    }

    // MARK: Zoom label

    func flashLabel(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 20, height: label.frame.height + 8)
        labelBackground.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                       width: size.width, height: size.height)
        labelBackground.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        label.frame.origin = CGPoint(x: 10, y: 4)
        labelBackground.alphaValue = 1
        labelTask?.cancel()
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.25
            self?.labelBackground.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }
}
