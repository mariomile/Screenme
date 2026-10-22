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

    /// Repeat capture: the picker stays open after each area or window pick, which `shoot` turns into a capture,
    /// and the selection stays so it can be shot again (Return) or adjusted. Returns when the user closes it with Esc.
    static func selectRepeatedly(shoot: @escaping (SelectionResult) async -> Void) async {
        _ = await SelectionSession(mode: .screenshot, delivery: .repeating(shoot)).run()
    }
}

/// The area the user is picking, in global Cocoa coordinates.
enum Selection {
    case none
    /// The button is down: the selection follows the pointer until it is released or Return confirms it.
    case dragging(Drag)
    /// A repeat capture's selection after a shot: Return shoots it again, the arrows adjust it, a new drag replaces it.
    case held(rect: CGRect, screen: NSScreen)

    struct Drag {
        let screen: NSScreen
        var anchor: CGPoint
        var corner: CGPoint
        /// Where the moving corner sits relative to the pointer (changes while Space moves the selection).
        var cornerOffset = CGSize.zero
        /// The selection after an arrow key moved or resized it: shown as is, whatever modifiers are held,
        /// until the pointer moves again.
        var nudged: CGRect?

        init(at point: CGPoint, on screen: NSScreen) {
            self.screen = screen
            anchor = Selection.clamp(point, to: screen.frame)
            corner = anchor
        }

        /// The selection as the user sees it: `flags` applied unless an arrow key set it, kept on the display, whole points.
        func rect(modifiers flags: NSEvent.ModifierFlags) -> CGRect {
            nudged ?? dragRect(modifiers: flags)
        }

        /// The pointer moved by `delta` to `pointer`. With Space held the whole selection follows it instead of
        /// being resized.
        mutating func follow(_ pointer: CGPoint, delta: CGPoint, spaceHeld: Bool, modifiers flags: NSEvent.ModifierFlags) {
            if delta != .zero { nudged = nil }
            if spaceHeld {
                let bounds = screen.frame
                let rect = rect(modifiers: flags)
                let dx = max(bounds.minX - rect.minX, min(delta.x, bounds.maxX - rect.maxX))
                let dy = max(bounds.minY - rect.minY, min(delta.y, bounds.maxY - rect.maxY))
                anchor.x += dx; anchor.y += dy
                corner.x += dx; corner.y += dy
                cornerOffset = CGSize(width: corner.x - pointer.x, height: corner.y - pointer.y)
            } else {
                corner = Selection.clamp(CGPoint(x: pointer.x + cornerOffset.width, y: pointer.y + cornerOffset.height), to: screen.frame)
            }
        }

        /// An arrow key set the selection to `rect`; the corner keeps following the pointer from where it is now.
        mutating func nudge(to rect: CGRect, pointer: CGPoint) {
            anchor = CGPoint(x: rect.minX, y: rect.minY)
            corner = CGPoint(x: rect.maxX, y: rect.maxY)
            cornerOffset = CGSize(width: corner.x - pointer.x, height: corner.y - pointer.y)
            nudged = rect
        }

        /// The drag's rectangle with `flags` applied: Shift makes it square, Option draws it from the center.
        private func dragRect(modifiers flags: NSEvent.ModifierFlags) -> CGRect {
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
    }

    /// The display the selection is on.
    var screen: NSScreen? {
        switch self {
        case .none: nil
        case .dragging(let drag): drag.screen
        case .held(_, let screen): screen
        }
    }

    /// What the user sees selected, nil when nothing is.
    func rect(modifiers flags: NSEvent.ModifierFlags) -> CGRect? {
        switch self {
        case .none: nil
        case .dragging(let drag): drag.rect(modifiers: flags)
        case .held(let rect, _): rect
        }
    }

    var isDragging: Bool {
        if case .dragging = self { true } else { false }
    }

    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}

/// One run of the picker: owns the panels, the pointer, the drag and the way out.
@MainActor
final class SelectionSession {
    /// Where a pick goes.
    enum Delivery {
        /// The pick ends the picker.
        case once
        /// Repeat capture: each pick goes to `shoot` and the picker stays open.
        case repeating(_ shoot: (SelectionResult) async -> Void)
    }

    /// How the picker looks and behaves, which follows from its mode and delivery.
    struct Behavior {
        /// Freezing only makes sense when the result is a still taken from the snapshot; every shot of a repeat is fresh.
        let freeze: Bool
        /// Off while repeating: the picker is not frozen, so the pixels it loaded at the start go stale after the first shot.
        let magnifier: Bool
        /// A repeat capture sits below the Quick Access cards and toasts of its own shots.
        let level: NSWindow.Level
        /// The hint's parts while picking an area and while picking a window.
        let areaHint: [String]
        let windowHint: [String]

        init(mode: SelectionMode, delivery: Delivery) {
            let repeating = if case .repeating = delivery { true } else { false }
            freeze = Prefs[Pref.freezeScreen] && (mode == .screenshot || mode == .window || mode == .text) && !repeating
            magnifier = Prefs[Pref.showMagnifier] && !repeating
            level = repeating ? .statusBar : .screenSaver
            switch mode {
            case _ where repeating:
                areaHint = ["Drag to capture an area", "Enter to capture again", "Space for window", "Esc to close"]
                windowHint = ["Click a window to capture it", "Space for area", "Esc to close"]
            case .recording:
                areaHint = ["Drag to record an area", "Space for window", "Enter for full screen", "Esc to cancel"]
                windowHint = ["Click a window to record it", "Space for area", "Enter for full screen", "Esc to cancel"]
            case .scrolling:
                areaHint = ["Drag over the area to scroll", "Space for window", "Esc to cancel"]
                windowHint = ["Click the window to scroll", "Space for area", "Esc to cancel"]
            case .text:
                areaHint = ["Drag to capture text", "Space for window", "Esc to cancel"]
                windowHint = ["Click a window to capture its text", "Space for area", "Esc to cancel"]
            case .screenshot, .window:
                areaHint = ["Drag to capture an area", "Space for window", "Esc to cancel"]
                windowHint = ["Click a window to capture it", "Space for area", "Esc to cancel"]
            }
        }
    }

    private let mode: SelectionMode
    private let delivery: Delivery
    private let behavior: Behavior
    private let showCrosshair = Prefs[Pref.showCrosshair]
    private var shooting = false
    private var shotTask: Task<Void, Never>?
    private let retina = Prefs[Pref.retinaResolution]

    private var windowMode: Bool
    private var snapshot = ScreenSnapshot()
    /// False until the window list is in `snapshot` (it arrives after the picker shows when the screen is not frozen).
    private var windowsLoaded = false
    /// A window click that came before the window list: picked as soon as the list arrives.
    private var pendingWindowClick: CGPoint?
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []

    // Pointer and selection, all in global Cocoa coordinates.
    private var pointer = NSEvent.mouseLocation
    private var selection = Selection.none
    private var spaceHeld = false

    // Lifecycle
    private var previousApp: NSRunningApplication?
    private var cursorHidden = false
    private var events: OverlayEventTap?
    /// Runs only while a drag is in progress.
    private var dragTimer: Timer?
    private var finished = false
    private var outcome: SelectionResult??
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    init(mode: SelectionMode, delivery: Delivery = .once) {
        self.mode = mode
        self.delivery = delivery
        behavior = Behavior(mode: mode, delivery: delivery)
        windowMode = mode == .window
    }

    func run() async -> SelectionResult? {
        previousApp = FocusKeeper.frontmostExternal()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // A frozen picker needs the picture before it can show. Otherwise show at once and fill in later.
        if behavior.freeze {
            snapshot = await SnapshotLoader.load(screens: screens, images: true, showsCursor: Prefs[Pref.showCursorInShots])
            windowsLoaded = true
        }
        present(screens)
        if !behavior.freeze {
            Task { await loadLate(screens) }
        }

        let result: SelectionResult? = await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
        // Closing a repeat capture lets a shot in flight finish first.
        await shotTask?.value
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
        let loaded = await SnapshotLoader.load(screens: screens, images: behavior.magnifier, showsCursor: false)
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
            let panel = OverlayPanel(screen: screen, level: behavior.level)
            let view = OverlayView(screen: screen, backdrop: behavior.freeze ? snapshot.images[screen.displayID] : nil)
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

        // Across displays with a button held no event arrives at all, so a drag also polls (`startDragPolling`).
        events = OverlayEventTap([
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown,
            .keyDown, .keyUp, .flagsChanged,
        ], handle: { [weak self] in self?.handle($0) ?? false },
           pointerMoved: { [weak self] in self?.followPointer() },
           screensChanged: { [weak self] in self?.finish(nil) })
    }

    private func teardown() {
        events?.stop()
        events = nil
        stopDragPolling()
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
        if case .dragging(var drag) = selection {
            drag.follow(location, delta: delta, spaceHeld: spaceHeld, modifiers: NSEvent.modifierFlags)
            selection = .dragging(drag)
        }
        refresh()
    }

    /// The pointer as it is now, when it moved: for moves seen by the global monitor or the drag timer.
    private func followPointer() {
        guard !finished else { return }
        let location = NSEvent.mouseLocation
        if location != pointer { pointerMoved(to: location) }
    }

    private func startDragPolling() {
        stopDragPolling()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragPolling() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func mouseDown() {
        if windowMode { return }
        selection = .dragging(Selection.Drag(at: pointer, on: NSScreen.at(pointer)))
        startDragPolling()
        refresh()
    }

    private func mouseUp() {
        if windowMode {
            if windowsLoaded { pickWindow(at: pointer) } else { pendingWindowClick = pointer }
            return
        }
        confirmDrag()
    }

    /// Ends the drag with the selection as it is now: a capture when it is big enough, otherwise back to picking.
    /// The button release and Return both come here.
    private func confirmDrag() {
        guard case .dragging(let drag) = selection else { return }
        let screen = drag.screen
        let rect = drag.rect(modifiers: NSEvent.modifierFlags)
        stopDragPolling()
        spaceHeld = false
        if rect.width >= 3, rect.height >= 3 {
            // A repeat capture keeps the selection on screen for the next shot.
            switch delivery {
            case .once: selection = .none
            case .repeating: selection = .held(rect: rect, screen: screen)
            }
            deliver(SelectionResult(target: .area(rect, screen), frozenImage: frozenImage(forArea: rect, on: screen)))
            return
        }
        selection = .none
        if mode == .recording {
            finish(SelectionResult(target: .display(screen), frozenImage: nil))
        } else {
            refresh()
        }
    }

    /// Ends the picker with `result`, or in a repeat capture takes the shot and stays open.
    /// A second pick while a shot is still being taken is ignored.
    private func deliver(_ result: SelectionResult) {
        guard case .repeating(let shoot) = delivery else {
            finish(result)
            return
        }
        guard !shooting else { return }
        shooting = true
        shotTask = Task { [weak self] in
            await shoot(result)
            self?.shooting = false
        }
        refresh()
    }

    private func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(nil)
        case kVK_Space:
            guard !event.isARepeat else { return }
            if selection.isDragging {
                spaceHeld = true
            } else {
                windowMode.toggle()
                // A held selection of a repeat capture gives way to picking a window.
                selection = .none
                for view in views { view.setHint(hintText()) }
                refresh()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            switch selection {
            case .dragging:
                confirmDrag()
            case .held(let rect, let screen):
                deliver(SelectionResult(target: .area(rect, screen), frozenImage: nil))
            case .none:
                if mode == .recording { finish(SelectionResult(target: .display(NSScreen.at(pointer)), frozenImage: nil)) }
            }
        case kVK_LeftArrow: arrowPressed(.left, dx: -1, dy: 0)
        case kVK_RightArrow: arrowPressed(.right, dx: 1, dy: 0)
        case kVK_UpArrow: arrowPressed(.up, dx: 0, dy: 1)
        case kVK_DownArrow: arrowPressed(.down, dx: 0, dy: -1)
        default: break
        }
    }

    /// With a selection (the button is held) an arrow moves it by one point, ten with Shift; with Option it resizes
    /// from the bottom and right edges. Without one it moves the pointer.
    private func arrowPressed(_ arrow: SelectionNudge.Arrow, dx: CGFloat, dy: CGFloat) {
        let flags = NSEvent.modifierFlags
        // Shift and Option mean step size and resize here, not square and from the center.
        func nudged(_ rect: CGRect, on screen: NSScreen) -> CGRect {
            SelectionNudge.apply(arrow, to: rect, step: SelectionNudge.step(shift: flags.contains(.shift)),
                                 resize: flags.contains(.option), within: screen.frame)
        }
        switch selection {
        case .dragging(var drag) where !windowMode:
            drag.nudge(to: nudged(drag.rect(modifiers: []), on: drag.screen), pointer: pointer)
            selection = .dragging(drag)
        case .held(let rect, let screen) where !windowMode:
            selection = .held(rect: nudged(rect, on: screen), screen: screen)
        default:
            nudge(dx: dx, dy: dy)
            return
        }
        refresh()
    }

    /// Moves the real mouse by one point (ten with Shift) for pixel precision.
    private func nudge(dx: CGFloat, dy: CGFloat) {
        let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
        let frame = (selection.screen ?? NSScreen.at(pointer)).frame
        let target = CGPoint(x: min(max(pointer.x + dx * step, frame.minX), frame.maxX - 1),
                             y: min(max(pointer.y + dy * step, frame.minY + 1), frame.maxY))
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: CaptureTarget.primaryHeight - target.y))
        pointerMoved(to: target)
    }

    // MARK: Geometry

    private func window(at point: CGPoint) -> WindowEntry? {
        snapshot.windows.first { $0.frame.contains(point) }
    }

    // MARK: Frozen result

    private func frozenImage(forArea rect: CGRect, on screen: NSScreen) -> CGImage? {
        guard behavior.freeze, let image = snapshot.images[screen.displayID] else { return nil }
        return image.cropped(to: rect, on: screen, retina: retina)
    }

    /// A window is never cut from the frozen screen, which would hold the windows overlapping it and lose its shadow:
    /// the capture takes the window on its own (`SCContentFilter(desktopIndependentWindow:)`), frozen or not.
    private func pickWindow(at point: CGPoint) {
        guard let entry = window(at: point) else { return }
        deliver(SelectionResult(target: .window(entry.window), frozenImage: nil))
    }

    // MARK: Drawing

    private func refresh() {
        guard !finished else { return }
        let selectedScreen = self.selection.screen
        let activeScreen = selectedScreen ?? NSScreen.at(pointer)
        let pointerPoint = selectedScreen.map { Selection.clamp(pointer, to: $0.frame) } ?? pointer
        let dragging = self.selection.isDragging
        let selection = self.selection.rect(modifiers: NSEvent.modifierFlags)
        let hovered = windowMode && !dragging ? window(at: pointer) : nil
        let style: PointerStyle = windowMode ? .glyph(pointerSymbol) : (showCrosshair ? .full : .small)

        for view in views {
            var state = OverlayState()
            let isActive = view.screen === activeScreen
            state.pointerStyle = style
            state.hintVisible = isActive && !dragging
            if isActive {
                state.pointer = pointerPoint
                if behavior.magnifier, !windowMode, view.source != nil {
                    let frame = view.screen.frame
                    let coordinates = "\(Int(pointerPoint.x - frame.minX)), \(Int(frame.maxY - pointerPoint.y))"
                    var size: String?
                    if let selection { size = "\(Int(selection.width)) × \(Int(selection.height))" }
                    state.loupe = LoupeInfo(coordinates: coordinates, size: size)
                }
            }
            if view.screen === selectedScreen, let selection, selection.width >= 1 || selection.height >= 1 {
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
        let parts = windowMode ? behavior.windowHint : behavior.areaHint
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
