import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum SelectionMode { case screenshot, window, recording, scrolling, text }

/// What the picker returns. `frozenImage` is set when the screen was frozen during an area selection:
/// it is already cropped to the target and should be used instead of a fresh capture. A window is always captured fresh.
struct SelectionResult {
    let target: CaptureTarget
    let frozenImage: CGImage?
}

/// Full-screen picker: drag for an area, Space for a window, Esc to cancel.
/// One at a time: only `CaptureCoordinator` calls it, inside its busy window.
@MainActor
enum SelectionOverlay {
    /// Shows the picker and returns the user's choice, or nil when cancelled.
    static func select(_ mode: SelectionMode) async -> SelectionResult? {
        await SelectionSession(mode: mode).run()
    }
}

/// One run of the picker: owns the panels, the pointer, the drag and the way out.
@MainActor
final class SelectionSession {
    private let mode: SelectionMode
    private let freeze: Bool
    private let showCrosshair = Prefs[Pref.showCrosshair]
    private let showMagnifier = Prefs[Pref.showMagnifier]
    private let retina = Prefs[Pref.retinaResolution]

    private var windowMode: Bool
    private var snapshot = ScreenSnapshot()
    /// False until the window list is in `snapshot` (it arrives after the picker shows when the screen is not frozen).
    private var windowsLoaded = false
    /// A window click that came before the window list: picked as soon as the list arrives.
    private var pendingWindowClick: CGPoint?
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []

    // Pointer and drag, all in global Cocoa coordinates.
    private var pointer = NSEvent.mouseLocation
    private var dragging = false
    private var dragScreen: NSScreen?
    private var anchor = CGPoint.zero
    private var corner = CGPoint.zero
    /// Where the moving corner sits relative to the pointer (changes while Space moves the selection).
    private var cornerOffset = CGSize.zero
    private var spaceHeld = false

    // Lifecycle
    private var previousApp: NSRunningApplication?
    private var cursorHidden = false
    private var eventMonitor: Any?
    private var tickTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var finished = false
    private var outcome: SelectionResult??
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    init(mode: SelectionMode) {
        self.mode = mode
        windowMode = mode == .window
        // Freezing only makes sense when the result is a still taken from the snapshot.
        freeze = Prefs[Pref.freezeScreen] && (mode == .screenshot || mode == .window || mode == .text)
    }

    func run() async -> SelectionResult? {
        previousApp = FocusKeeper.frontmostExternal()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // A frozen picker needs the picture before it can show. Otherwise show at once and fill in later.
        if freeze {
            snapshot = await SnapshotLoader.load(screens: screens, images: true, showsCursor: Prefs[Pref.showCursorInShots])
            windowsLoaded = true
        }
        present(screens)
        if !freeze {
            Task { await loadLate(screens) }
        }

        let result: SelectionResult? = await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
        // A cancel has no screenshot to wait for: hand focus back in the background.
        let app = previousApp
        if result == nil {
            Task { await FocusKeeper.restore(app) }
        } else {
            await FocusKeeper.restore(app)
        }
        return result
    }

    /// Window list and magnifier pixels, loaded while the picker is already on screen.
    private func loadLate(_ screens: [NSScreen]) async {
        let loaded = await SnapshotLoader.load(screens: screens, images: showMagnifier, showsCursor: false)
        guard !finished else { return }
        snapshot = loaded
        windowsLoaded = true
        if let click = pendingWindowClick {
            pendingWindowClick = nil
            pickWindow(at: click)
            if finished { return }
        }
        for view in views { view.source = loaded.images[view.screen.displayID] }
        refresh()
    }

    // MARK: Presenting

    private func present(_ screens: [NSScreen]) {
        FocusKeeper.allowBackgroundCursor()
        let hint = hintText()
        for screen in screens {
            let panel = OverlayPanel(screen: screen)
            let view = OverlayView(screen: screen, backdrop: freeze ? snapshot.images[screen.displayID] : nil)
            view.source = snapshot.images[screen.displayID]
            view.setHint(hint)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
        refresh()

        for panel in panels { panel.orderFrontRegardless() }
        let keyIndex = views.firstIndex { $0.screen === NSScreen.at(pointer) } ?? 0
        panels[keyIndex].makeKeyAndOrderFront(nil)
        panels.forEach { $0.invalidateCursorRects(for: $0.contentView!) }
        FocusKeeper.activateSelf()
        NSCursor.hide()
        cursorHidden = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown,
            .keyDown, .keyUp, .flagsChanged,
        ]) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated { self.handle(box.event) }
            return consumed ? nil : event
        }
        // Mouse-moved events are not delivered reliably to panels of an inactive app,
        // and never across displays while a button is held, so poll as well.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let location = NSEvent.mouseLocation
                if location != self.pointer { self.pointerMoved(to: location) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func teardown() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        tickTimer?.invalidate()
        tickTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    private func finish(_ result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        teardown()
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            outcome = .some(result)
        }
    }

    // MARK: Events

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        switch event.type {
        case .mouseMoved:
            pointerMoved(to: NSEvent.mouseLocation)
        case .leftMouseDown:
            pointerMoved(to: NSEvent.mouseLocation)
            mouseDown()
        case .leftMouseDragged:
            pointerMoved(to: NSEvent.mouseLocation)
        case .leftMouseUp:
            pointerMoved(to: NSEvent.mouseLocation)
            mouseUp()
        case .rightMouseDown, .otherMouseDown:
            finish(nil)
        case .flagsChanged:
            refresh()
            return false
        case .keyDown:
            keyDown(event)
        case .keyUp:
            if Int(event.keyCode) == kVK_Space { spaceHeld = false }
        default:
            return false
        }
        return true
    }

    private func pointerMoved(to location: CGPoint) {
        let delta = CGPoint(x: location.x - pointer.x, y: location.y - pointer.y)
        pointer = location
        if dragging, let screen = dragScreen {
            if spaceHeld {
                translateSelection(by: delta, within: screen.frame)
            } else {
                corner = Self.clamp(CGPoint(x: location.x + cornerOffset.width, y: location.y + cornerOffset.height), to: screen.frame)
            }
        }
        refresh()
    }

    private func mouseDown() {
        if windowMode { return }
        let screen = NSScreen.at(pointer)
        dragScreen = screen
        anchor = Self.clamp(pointer, to: screen.frame)
        corner = anchor
        cornerOffset = .zero
        dragging = true
        refresh()
    }

    private func mouseUp() {
        if windowMode {
            if windowsLoaded { pickWindow(at: pointer) } else { pendingWindowClick = pointer }
            return
        }
        guard dragging, let screen = dragScreen else { return }
        let rect = selectionRect()
        dragging = false
        dragScreen = nil
        spaceHeld = false
        if rect.width >= 3, rect.height >= 3 {
            finish(SelectionResult(target: .area(rect, screen), frozenImage: frozenImage(forArea: rect, on: screen)))
        } else if mode == .recording {
            finish(SelectionResult(target: .display(screen), frozenImage: nil))
        } else {
            refresh()
        }
    }

    private func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(nil)
        case kVK_Space:
            guard !event.isARepeat else { return }
            if dragging {
                spaceHeld = true
            } else {
                windowMode.toggle()
                for view in views { view.setHint(hintText()) }
                refresh()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mode == .recording { finish(SelectionResult(target: .display(NSScreen.at(pointer)), frozenImage: nil)) }
        case kVK_LeftArrow: nudge(dx: -1, dy: 0)
        case kVK_RightArrow: nudge(dx: 1, dy: 0)
        case kVK_UpArrow: nudge(dx: 0, dy: 1)
        case kVK_DownArrow: nudge(dx: 0, dy: -1)
        default: break
        }
    }

    /// Moves the real mouse by one point (ten with Shift) for pixel precision.
    private func nudge(dx: CGFloat, dy: CGFloat) {
        let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
        let frame = (dragScreen ?? NSScreen.at(pointer)).frame
        let target = CGPoint(x: min(max(pointer.x + dx * step, frame.minX), frame.maxX - 1),
                             y: min(max(pointer.y + dy * step, frame.minY + 1), frame.maxY))
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: CaptureTarget.primaryHeight - target.y))
        pointerMoved(to: target)
    }

    // MARK: Geometry

    private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func window(at point: CGPoint) -> WindowEntry? {
        snapshot.windows.first { $0.frame.contains(point) }
    }

    /// The selection as the user sees it: modifiers applied, kept on the display, whole points.
    private func selectionRect() -> CGRect {
        guard let screen = dragScreen else { return .zero }
        let flags = NSEvent.modifierFlags
        let bounds = screen.frame
        let dx = corner.x - anchor.x, dy = corner.y - anchor.y
        let signX: CGFloat = dx < 0 ? -1 : 1, signY: CGFloat = dy < 0 ? -1 : 1
        let fromCenter = flags.contains(.option)

        var width = abs(dx), height = abs(dy)
        if flags.contains(.shift) {
            let side = max(width, height)
            width = side
            height = side
        }
        let roomX = fromCenter ? min(anchor.x - bounds.minX, bounds.maxX - anchor.x) : (signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX)
        let roomY = fromCenter ? min(anchor.y - bounds.minY, bounds.maxY - anchor.y) : (signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY)
        width = min(width, roomX)
        height = min(height, roomY)
        if flags.contains(.shift) {
            let side = min(width, height)
            width = side
            height = side
        }

        let raw: CGRect
        if fromCenter {
            raw = CGRect(x: anchor.x - width, y: anchor.y - height, width: width * 2, height: height * 2)
        } else {
            raw = CGRect(x: signX > 0 ? anchor.x : anchor.x - width, y: signY > 0 ? anchor.y : anchor.y - height,
                         width: width, height: height)
        }
        let snapped = CGRect(x: raw.minX.rounded(), y: raw.minY.rounded(),
                             width: raw.maxX.rounded() - raw.minX.rounded(), height: raw.maxY.rounded() - raw.minY.rounded())
        return snapped.intersection(bounds)
    }

    /// Space held: the whole selection follows the pointer instead of being resized.
    private func translateSelection(by delta: CGPoint, within bounds: CGRect) {
        let rect = selectionRect()
        let dx = max(bounds.minX - rect.minX, min(delta.x, bounds.maxX - rect.maxX))
        let dy = max(bounds.minY - rect.minY, min(delta.y, bounds.maxY - rect.maxY))
        anchor.x += dx; anchor.y += dy
        corner.x += dx; corner.y += dy
        cornerOffset = CGSize(width: corner.x - pointer.x, height: corner.y - pointer.y)
    }

    // MARK: Frozen result

    private func frozenImage(forArea rect: CGRect, on screen: NSScreen) -> CGImage? {
        guard freeze, let image = snapshot.images[screen.displayID] else { return nil }
        return image.cropped(to: rect, on: screen, retina: retina)
    }

    /// A window is never cut from the frozen screen, which would hold the windows overlapping it and lose its shadow:
    /// the capture takes the window on its own (`SCContentFilter(desktopIndependentWindow:)`), frozen or not.
    private func pickWindow(at point: CGPoint) {
        guard let entry = window(at: point) else { return }
        finish(SelectionResult(target: .window(entry.window), frozenImage: nil))
    }

    // MARK: Drawing

    private func refresh() {
        guard !finished else { return }
        let activeScreen = dragScreen ?? NSScreen.at(pointer)
        let pointerPoint = dragScreen.map { Self.clamp(pointer, to: $0.frame) } ?? pointer
        let selection: CGRect? = dragging ? selectionRect() : nil
        let hovered = windowMode && !dragging ? window(at: pointer) : nil
        let style: PointerStyle = windowMode ? .glyph(pointerSymbol) : (showCrosshair ? .full : .small)

        for view in views {
            var state = OverlayState()
            let isActive = view.screen === activeScreen
            state.pointerStyle = style
            state.hintVisible = isActive && !dragging
            if isActive {
                state.pointer = pointerPoint
                if showMagnifier, !windowMode, view.source != nil {
                    let frame = view.screen.frame
                    let coordinates = "\(Int(pointerPoint.x - frame.minX)), \(Int(frame.maxY - pointerPoint.y))"
                    var size: String?
                    if let selection { size = "\(Int(selection.width)) × \(Int(selection.height))" }
                    state.loupe = LoupeInfo(coordinates: coordinates, size: size)
                }
            }
            if view.screen === dragScreen, let selection, selection.width >= 1 || selection.height >= 1 {
                state.selection = selection
            }
            if let hovered {
                state.windowRect = hovered.frame
                if isActive {
                    state.windowLabel = "\(hovered.appName)  ·  \(Int(hovered.frame.width)) × \(Int(hovered.frame.height))"
                }
            }
            view.apply(state)
        }
    }

    private var pointerSymbol: String {
        switch mode {
        case .recording: "video.fill"
        case .text: "text.viewfinder"
        case .scrolling: "arrow.up.and.down"
        case .screenshot, .window: "camera.fill"
        }
    }

    // MARK: Hint

    private func hintText() -> NSAttributedString {
        let parts: [String]
        switch (mode, windowMode) {
        case (.recording, false): parts = ["Drag to record an area", "Space for window", "Enter for full screen", "Esc to cancel"]
        case (.recording, true): parts = ["Click a window to record it", "Space for area", "Enter for full screen", "Esc to cancel"]
        case (.scrolling, false): parts = ["Drag over the area to scroll", "Space for window", "Esc to cancel"]
        case (.scrolling, true): parts = ["Click the window to scroll", "Space for area", "Esc to cancel"]
        case (.text, false): parts = ["Drag to capture text", "Space for window", "Esc to cancel"]
        case (.text, true): parts = ["Click a window to capture its text", "Space for area", "Esc to cancel"]
        case (_, false): parts = ["Drag to capture an area", "Space for window", "Esc to cancel"]
        case (_, true): parts = ["Click a window to capture it", "Space for area", "Esc to cancel"]
        }
        let regular = NSFont.systemFont(ofSize: 13, weight: .regular)
        let strong = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ·   ", attributes: [.font: regular, .foregroundColor: NSColor.white.withAlphaComponent(0.4)]))
            }
            let piece = NSMutableAttributedString(string: part, attributes: [.font: regular, .foregroundColor: NSColor.white.withAlphaComponent(0.78)])
            for key in ["Space", "Enter", "Esc"] {
                let range = (part as NSString).range(of: key)
                if range.location == 0 {
                    piece.addAttributes([.font: strong, .foregroundColor: NSColor.white], range: range)
                }
            }
            if index == 0 { piece.addAttributes([.foregroundColor: NSColor.white], range: NSRange(location: 0, length: piece.length)) }
            result.append(piece)
        }
        return result
    }
}
