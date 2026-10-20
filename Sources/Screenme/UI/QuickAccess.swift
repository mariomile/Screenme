import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Controller

/// The card that slides in after every capture: drag it into any app, or copy, save, annotate, pin.
/// Each card is a non-activating panel, so it never takes focus from the app the user is in.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    /// Room around the visible card for its shadow.
    fileprivate static let inset: CGFloat = 24
    fileprivate static let cardWidth: CGFloat = 224
    private let margin: CGFloat = 16
    private let gap: CGFloat = 12

    private var cards: [QuickAccessCard] = []
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var updateObserver: NSObjectProtocol?

    private init() {
        updateObserver = NotificationCenter.default.addObserver(forName: Notification.Name("ScreenmeCaptureUpdated"), object: nil, queue: .main) { note in
            guard let url = Self.fileURL(from: note.object) else { return }
            MainActor.assumeIsolated { QuickAccess.shared.reload(url) }
        }
    }

    private nonisolated static func fileURL(from object: Any?) -> URL? {
        if let url = object as? URL { return url }
        if let path = object as? String { return URL(fileURLWithPath: path) }
        return nil
    }

    // MARK: Showing

    func show(_ item: CaptureItem) {
        // A new version of a capture already on screen replaces its card.
        for old in cards where old.model.item.url == item.url && !old.isDismissing { remove(old) }

        let screen = NSScreen.underMouse
        let card = QuickAccessCard(item: item, screen: screen, owner: self)
        cards.append(card)
        trimOverflow(on: screen)
        layout()

        card.origin = CGPoint(x: card.rest.x + card.edgeSign * card.size.width * 0.9, y: card.rest.y)
        card.panel.alphaValue = 0
        card.panel.setFrameOrigin(card.origin)
        card.panel.orderFrontRegardless()
        card.target = card.rest
        startTimer()
        card.scheduleAutoClose()
    }

    // MARK: Layout

    /// Stacks the cards of each screen in its corner, newest at the bottom.
    private func layout() {
        let rightSide = Prefs[Pref.quickAccessPosition] == .bottomRight
        var offsets: [CGDirectDisplayID: CGFloat] = [:]
        for card in cards.reversed() where !card.isDismissing {
            let area = card.screen.visibleFrame
            let inset = Self.inset
            card.edgeSign = rightSide ? 1 : -1
            let x = rightSide ? area.maxX - margin - card.size.width - inset : area.minX + margin - inset
            let offset = offsets[card.screen.displayID, default: 0]
            card.rest = CGPoint(x: x, y: area.minY + margin - inset + offset)
            offsets[card.screen.displayID] = offset + card.size.height + gap
            if !card.isHeld { card.target = card.rest }
        }
        startTimer()
    }

    /// Drops the oldest cards when the stack would not fit on the screen.
    private func trimOverflow(on screen: NSScreen) {
        while true {
            let stack = cards.filter { $0.screen === screen && !$0.isDismissing }
            let height = stack.reduce(margin) { $0 + $1.size.height + gap }
            guard height > screen.visibleFrame.height - margin, stack.count > 1, let oldest = stack.first else { return }
            dismiss(oldest)
        }
    }

    // MARK: Dismissing

    func dismiss(_ card: QuickAccessCard, velocity: CGFloat = 0) {
        guard !card.isDismissing else { return }
        card.isDismissing = true
        card.isHeld = false
        card.cancelAutoClose()
        card.velocity = CGPoint(x: velocity, y: 0)
        card.target = CGPoint(x: card.rest.x + card.edgeSign * card.size.width * 1.2, y: card.origin.y)
        layout()
    }

    fileprivate func remove(_ card: QuickAccessCard) {
        card.cancelAutoClose()
        card.panel.orderOut(nil)
        cards.removeAll { $0 === card }
        layout()
    }

    private func reload(_ url: URL) {
        let path = url.standardizedFileURL.path
        for card in cards where card.model.item.url.standardizedFileURL.path == path {
            Task { await card.model.reload() }
        }
    }

    // MARK: Spring animation

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { QuickAccess.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30.0))
        lastTick = now
        for card in cards where !card.isHeld {
            card.step(dt)
            if card.isDismissing && card.panel.alphaValue < 0.02 { remove(card) }
        }
        if !cards.contains(where: { !$0.isHeld && $0.needsMotion }) {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Swiping

    fileprivate func swipeChanged(_ card: QuickAccessCard, dx: CGFloat) {
        card.isHeld = true
        card.cancelAutoClose()
        // Toward the edge follows the finger, away from it resists.
        let toward = dx * card.edgeSign
        let shown = toward > 0 ? toward : toward * 0.2
        card.setOffset(shown * card.edgeSign)
    }

    fileprivate func swipeEnded(_ card: QuickAccessCard, dx: CGFloat, velocityX: CGFloat) {
        let toward = dx * card.edgeSign
        if toward > 70 || velocityX * card.edgeSign > 700 {
            dismiss(card, velocity: velocityX)
        } else {
            card.isHeld = false
            card.velocity = CGPoint(x: velocityX, y: 0)
            card.target = card.rest
            card.scheduleAutoClose()
            startTimer()
        }
    }

    // MARK: Actions

    fileprivate func copy(_ card: QuickAccessCard) {
        Clipboard.copy(card.model.item)
        Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        dismiss(card)
    }

    fileprivate func save(_ card: QuickAccessCard) {
        do {
            let saved = try Storage.save(card.model.item.url)
            let folder = saved.deletingLastPathComponent().lastPathComponent
            Toast.show("Saved to \(folder)", symbol: "square.and.arrow.down.fill")
            dismiss(card)
        } catch {
            Toast.show("Could not save", symbol: "exclamationmark.triangle.fill")
        }
    }

    fileprivate func saveAs(_ card: QuickAccessCard) {
        let item = card.model.item
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.directoryURL = Storage.saveDirectory
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: item.url.pathExtension) { panel.allowedContentTypes = [type] }
        // The save panel needs the app active; hand focus back to where it was afterwards.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { previous?.activate() }
        guard response == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: item.url, to: destination)
            Toast.show("Saved to \(destination.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")
            dismiss(card)
        } catch {
            Toast.show("Could not save", symbol: "exclamationmark.triangle.fill")
        }
    }

    fileprivate func reveal(_ card: QuickAccessCard) {
        NSWorkspace.shared.activateFileViewerSelecting([card.model.item.url])
    }

    fileprivate func edit(_ card: QuickAccessCard) {
        let item = card.model.item
        guard item.kind != .gif else { return } // neither editor opens GIFs
        dismiss(card)
        item.kind == .image ? AnnotationEditor.open(item) : VideoEditor.open(item)
    }

    fileprivate func pin(_ card: QuickAccessCard) {
        guard card.model.item.kind != .video else { return }
        PinWindow.pin(card.model.item)
        dismiss(card)
    }

    fileprivate func trash(_ card: QuickAccessCard) {
        try? FileManager.default.trashItem(at: card.model.item.url, resultingItemURL: nil)
        Toast.show("Moved to Trash", symbol: "trash.fill")
        dismiss(card)
    }
}

// MARK: - One card

@MainActor
final class QuickAccessCard {
    let model: CardModel
    let panel: CardPanel
    let size: CGSize
    let screen: NSScreen
    private unowned let owner: QuickAccess

    /// Panel origin, spring state, and where it should settle.
    var origin: CGPoint = .zero
    var velocity: CGPoint = .zero
    var target: CGPoint = .zero
    var rest: CGPoint = .zero
    /// -1 when the card sits at the left edge, 1 at the right edge.
    var edgeSign: CGFloat = -1
    var isDismissing = false
    /// True while a swipe or drag owns the position.
    var isHeld = false
    private var autoClose: DispatchWorkItem?

    init(item: CaptureItem, screen: NSScreen, owner: QuickAccess) {
        self.screen = screen
        self.owner = owner
        let width = QuickAccess.cardWidth
        let height = CGFloat.minimum(220, CGFloat.maximum(140, width * Thumbnail.aspectRatio(of: item)))
        size = CGSize(width: width, height: height)
        model = CardModel(item: item)

        let inset = QuickAccess.inset
        let frame = CGRect(x: 0, y: 0, width: width + inset * 2, height: height + inset * 2)
        panel = CardPanel(contentRect: frame)
        let root = CardRootView(frame: frame)
        let hosting = FirstMouseHostingView(rootView: QuickAccessCardView(model: model, size: size))
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)
        root.onHover = { [weak self] hovering in self?.hoverChanged(hovering) }
        panel.contentView = root

        model.actions = CardActions(
            copy: bind { $0.copy($1) },
            save: bind { $0.save($1) },
            saveAs: bind { $0.saveAs($1) },
            reveal: bind { $0.reveal($1) },
            edit: bind { $0.edit($1) },
            pin: bind { $0.pin($1) },
            trash: bind { $0.trash($1) },
            close: bind { $0.dismiss($1) },
            open: bind { $0.edit($1) },
            swipeChanged: { [weak self] dx in
                guard let self else { return }
                self.owner.swipeChanged(self, dx: dx)
            },
            swipeEnded: { [weak self] dx, velocity in
                guard let self else { return }
                self.owner.swipeEnded(self, dx: dx, velocityX: velocity)
            },
            dragStarted: { [weak self] in self?.dragStarted() },
            dragEnded: { [weak self] dropped in self?.dragEnded(dropped: dropped) },
            edgeSign: { [weak self] in self?.edgeSign ?? -1 }
        )
        Task { await model.reload() }
    }

    private func bind(_ run: @escaping (QuickAccess, QuickAccessCard) -> Void) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            run(self.owner, self)
        }
    }

    // MARK: Spring

    var needsMotion: Bool { origin != target || velocity != .zero }

    func step(_ dt: CGFloat) {
        let stiffness: CGFloat = 280
        let damping: CGFloat = isDismissing ? 34 : 25
        for axis in 0..<2 {
            let position = axis == 0 ? origin.x : origin.y
            let goal = axis == 0 ? target.x : target.y
            var v = axis == 0 ? velocity.x : velocity.y
            let acceleration = stiffness * (goal - position) - damping * v
            v += acceleration * dt
            var next = position + v * dt
            if abs(goal - next) < 0.3 && abs(v) < 8 {
                next = goal
                v = 0
            }
            if axis == 0 { origin.x = next; velocity.x = v } else { origin.y = next; velocity.y = v }
        }
        panel.setFrameOrigin(origin)
        updateAlpha()
    }

    /// Places the card `offset` points from its rest position, outside the spring (swipe in progress).
    func setOffset(_ offset: CGFloat) {
        origin.x = rest.x + offset
        velocity = .zero
        panel.setFrameOrigin(origin)
        updateAlpha()
    }

    private func updateAlpha() {
        let travel = abs(origin.x - rest.x) / (size.width * 0.9)
        panel.alphaValue = max(0, min(1, 1 - travel))
    }

    // MARK: Hover and auto close

    private func hoverChanged(_ hovering: Bool) {
        model.hovering = hovering
        if hovering { cancelAutoClose() } else { scheduleAutoClose() }
    }

    func scheduleAutoClose() {
        cancelAutoClose()
        let seconds = Prefs[Pref.quickAccessAutoClose]
        guard seconds > 0, !model.hovering, !model.dragging, !isDismissing else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.hovering, !self.model.dragging else { return }
                self.owner.dismiss(self)
            }
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    func cancelAutoClose() {
        autoClose?.cancel()
        autoClose = nil
    }

    // MARK: File drag

    private func dragStarted() {
        model.dragging = true
        cancelAutoClose()
    }

    private func dragEnded(dropped: Bool) {
        model.dragging = false
        if dropped {
            owner.dismiss(self)
        } else {
            scheduleAutoClose()
        }
    }
}

// MARK: - Panel and views

final class CardPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reports mouse enter and exit even though the panel is never key.
private final class CardRootView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
struct CardActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var reveal: () -> Void = {}
    var edit: () -> Void = {}
    var pin: () -> Void = {}
    var trash: () -> Void = {}
    var close: () -> Void = {}
    var open: () -> Void = {}
    var swipeChanged: (CGFloat) -> Void = { _ in }
    var swipeEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    var dragStarted: () -> Void = {}
    var dragEnded: (Bool) -> Void = { _ in }
    var edgeSign: () -> CGFloat = { -1 }
}

@MainActor
final class CardModel: ObservableObject {
    let item: CaptureItem
    @Published var thumbnail: NSImage?
    @Published var duration: String?
    @Published var hovering = false
    @Published var dragging = false
    var actions = CardActions()

    init(item: CaptureItem) { self.item = item }

    func reload() async {
        let image = await Thumbnail.make(for: item)
        thumbnail = image
        if item.kind == .video { duration = await Thumbnail.duration(of: item.url) }
    }
}

private struct QuickAccessCardView: View {
    @ObservedObject var model: CardModel
    let size: CGSize

    private var showsControls: Bool { model.hovering && !model.dragging }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }

            CardDragSurface(model: model)

            if showsControls { controls }

            if model.item.kind == .video, let duration = model.duration {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label(duration, systemImage: "video.fill")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
                .opacity(showsControls ? 0 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
        .opacity(model.dragging ? 0.4 : 1)
        .padding(QuickAccess.inset)
        .animation(.easeOut(duration: 0.15), value: showsControls)
        .animation(.easeOut(duration: 0.2), value: model.thumbnail == nil)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                HUDPill(title: "Copy", symbol: "doc.on.doc", action: model.actions.copy)
                HUDPill(title: "Save", symbol: "square.and.arrow.down", action: model.actions.save)
            }

            VStack {
                HStack {
                    HUDCircle(symbol: "xmark", label: "Close", action: model.actions.close)
                    Spacer()
                    if model.item.kind != .video {
                        HUDCircle(symbol: "pin.fill", label: "Pin to screen", action: model.actions.pin)
                    }
                }
                Spacer()
                HStack {
                    if model.item.kind != .gif {
                        HUDCircle(symbol: model.item.kind == .image ? "pencil.and.scribble" : "scissors",
                                  label: model.item.kind == .image ? "Annotate" : "Edit", action: model.actions.edit)
                    }
                    Spacer()
                }
            }
            .padding(8)
        }
        .transition(.opacity)
    }
}

private struct HUDPill: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 84, height: 28)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(HUDPressStyle())
    }
}

private struct HUDCircle: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(HUDPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HUDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Drag surface (AppKit)

/// Sits under the hover controls. Owns double-click, the right-click menu, swipe to dismiss and the file drag.
private struct CardDragSurface: NSViewRepresentable {
    let model: CardModel

    func makeNSView(context: Context) -> CardDragView { CardDragView(model: model) }
    func updateNSView(_ view: CardDragView, context: Context) { view.model = model }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

private final class CardDragView: NSView, NSDraggingSource {
    var model: CardModel

    private var downLocation: CGPoint = .zero
    private var downEvent: NSEvent?
    private enum Mode { case undecided, swiping, dragging }
    private var mode: Mode = .undecided
    private var lastSample: (x: CGFloat, time: TimeInterval) = (0, 0)
    private var velocityX: CGFloat = 0
    private var scrollOffset: CGFloat = 0

    init(model: CardModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        downEvent = event
        mode = .undecided
        velocityX = 0
        lastSample = (downLocation.x, event.timestamp)
        if event.clickCount == 2 { model.actions.open() }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        let dx = location.x - downLocation.x
        let dy = location.y - downLocation.y

        if mode == .undecided {
            guard hypot(dx, dy) >= 4 else { return }
            let sign = model.actions.edgeSign()
            // A mostly horizontal move toward the screen edge swipes the card away. Anything else drags the file out.
            mode = (abs(dx) > abs(dy) * 1.2 && dx * sign > 0) ? .swiping : .dragging
            if mode == .dragging { beginFileDrag(with: event) }
        }

        if mode == .swiping {
            let dt = event.timestamp - lastSample.time
            if dt > 0.001 { velocityX = (location.x - lastSample.x) / CGFloat(dt) }
            lastSample = (location.x, event.timestamp)
            model.actions.swipeChanged(dx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .swiping {
            model.actions.swipeEnded(NSEvent.mouseLocation.x - downLocation.x, velocityX)
        }
        mode = .undecided
    }

    // MARK: Trackpad swipe

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || scrollOffset != 0 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began, .changed:
            scrollOffset += delta
            model.actions.swipeChanged(scrollOffset)
        case .ended, .cancelled:
            let total = scrollOffset
            scrollOffset = 0
            model.actions.swipeEnded(total, 0)
        default:
            break
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let actions = model.actions
        let isImage = model.item.kind == .image
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action // keeps the handler alive as long as the menu
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Copy", "doc.on.doc", actions.copy)
        add("Save", "square.and.arrow.down", actions.save)
        add("Save As…", "square.and.arrow.down.on.square", actions.saveAs)
        add("Show in Finder", "folder", actions.reveal)
        menu.addItem(.separator())
        if model.item.kind != .gif { add(isImage ? "Annotate" : "Edit", isImage ? "pencil.and.scribble" : "scissors", actions.edit) }
        if model.item.kind != .video { add("Pin to Screen", "pin", actions.pin) }
        menu.addItem(.separator())
        add("Delete", "trash", actions.trash)
        return menu
    }

    // MARK: File drag

    private func beginFileDrag(with event: NSEvent) {
        let url = model.item.url
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = model.thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
        let maxSide: CGFloat = 150
        let aspect = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
        let dragSize = aspect >= 1 ? CGSize(width: maxSide, height: maxSide / aspect) : CGSize(width: maxSide * aspect, height: maxSide)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - dragSize.width / 2, y: point.y - dragSize.height / 2,
                                     width: dragSize.width, height: dragSize.height), contents: image)
        model.actions.dragStarted()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dropped = !operation.isEmpty
        model.actions.dragEnded(dropped)
    }
}

// MARK: - Thumbnails

enum Thumbnail {
    /// Height over width of the capture, read from the file header. 0.65 when unknown.
    static func aspectRatio(of item: CaptureItem) -> CGFloat {
        guard item.kind != .video,
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0 else { return 0.65 }
        return height / width
    }

    static func make(for item: CaptureItem) async -> NSImage? {
        switch item.kind {
        case .image, .gif:
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720,
                kCGImageSourceShouldCache: false,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return NSImage(contentsOf: item.url)
            }
            return NSImage(cgImage: image, size: .zero)
        case .video:
            let asset = AVURLAsset(url: item.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let time = CMTime(seconds: seconds > 1 ? 0.3 : 0, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time) else { return nil }
            return NSImage(cgImage: image, size: .zero)
        }
    }

    /// "0:12", "1:05", "1:02:03".
    static func duration(of url: URL) async -> String? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
