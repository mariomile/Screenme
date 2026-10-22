import AppKit
import ApplicationServices

/// Everything recorded during one recording: the size of the recorded area and the events in time order.
/// Kept in memory by recording file, and next to it as a hidden JSON file so a report made later still finds it.
/// Older files also hold `pointer`, a coarser pointer path the cursor track replaced; it is not read.
struct RecordingEvents: Codable, Equatable {
    var width: Double
    var height: Double
    var events: [RecordingEvent]
    /// Display and area recordings: the windows over the area, stored when they changed, about once a second.
    var windows: [WindowSnapshot]?
    /// The pointer's path and button presses, for the video editor's zoom and Smooth cursor, and for auto-crop.
    /// Nil in older recordings.
    var cursor: CursorTrack? = nil

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Store

    @MainActor private static var recorded: [URL: RecordingEvents] = [:]
    /// A recording that goes to the Trash is forgotten; its sidecar goes with it (`Sidecar.trash(with:)`).
    @MainActor private static let forgetsTrashed = Sidecar.onTrash { recorded[$0] = nil }

    /// Kept in memory and in the hidden sidecar `Sidecar.events` next to the recording.
    @MainActor
    static func record(_ events: RecordingEvents, for video: URL) {
        _ = forgetsTrashed
        recorded[video] = events
        try? events.json().write(to: Sidecar.events.url(for: video), options: .atomic)
    }

    /// The events of a recording, from memory or from its sidecar. Nil for recordings made without them.
    @MainActor
    static func events(for video: URL) -> RecordingEvents? {
        if let events = recorded[video] { return events }
        guard let data = try? Data(contentsOf: Sidecar.events.url(for: video)) else { return nil }
        return try? JSONDecoder().decode(RecordingEvents.self, from: data)
    }

    // MARK: Shortcuts

    /// The label for a key press worth recording, or nil. Only shortcuts (a key with ⌘, ⌃ or ⌥) and Return, Enter,
    /// Esc, Tab and the arrows: never plain typing, which may be a password.
    static func shortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String? {
        let commandLike = !flags.intersection([.command, .option, .control]).isEmpty
        let navigation: Set<UInt16> = [36, 76, 53, 48, 123, 124, 125, 126]
        guard commandLike || navigation.contains(keyCode) else { return nil }
        return RecordingEffects.label(keyCode: keyCode, flags: flags, characters: characters)
    }
}

/// Records the events of a running recording: clicks (with the element under the pointer when Accessibility is
/// allowed), drags, scrolls, shortcuts, app and window switches, drawings and pins, with the pointer's path through
/// its `CursorRecorder`. `time` gives the video time of now, nil while paused.
@MainActor
final class RecordingEventRecorder {
    private let area: CGRect
    private let recordsWindows: Bool
    private let cursorless: Bool
    private var time: @Sendable () -> Double?
    private var cursor: CursorRecorder
    private(set) var events: [RecordingEvent] = []
    private var windows: [WindowSnapshot] = []
    private var monitors: [Any] = []
    private var poll: Timer?
    private var lastApp: (app: String, window: String?)?
    /// Bumped by `restart`, so an element name looked up for a thrown-away take is not added to the new one.
    private var take = 0

    /// `area` is the recorded area in global Cocoa coordinates. `recordsWindows` (display and area recordings) also
    /// records the windows over it, so the report can crop each keyframe to where things happened. `cursorless`: the
    /// recording is filmed without the cursor (Smooth cursor).
    init(area: CGRect, recordsWindows: Bool, cursorless: Bool, time: @escaping @Sendable () -> Double?) {
        self.area = area
        self.recordsWindows = recordsWindows
        self.cursorless = cursorless
        self.time = time
        cursor = CursorRecorder(area: area, hidden: cursorless, time: time)
    }

    /// Everything recorded so far, events in time order, with the pointer's path.
    var recorded: RecordingEvents {
        RecordingEvents(width: area.width, height: area.height, events: events.sorted { $0.time < $1.time },
                        windows: recordsWindows ? windows : nil, cursor: cursor.track)
    }

    func start() {
        cursor.start()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.mouse(type) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let delta = CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            MainActor.assumeIsolated { self?.scroll(delta) }
        }) { monitors.append(monitor) }
        // Key events reach other apps' monitors only with Accessibility.
        if Permission.accessibility.isGranted, let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keys = RecordingEvents.shortcut(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated { if let keys { self?.add { .shortcut(keys, time: $0) } } }
        }) { monitors.append(monitor) }
        checkFrontApp()
        checkWindows()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkFrontApp()
                self?.checkWindows()
            }
        }
    }

    func stop() {
        cursor.stop()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        poll?.invalidate()
        poll = nil
    }

    /// A restart: what was recorded so far belongs to the take that was thrown away. The new take runs on `time`.
    func restart(time: @escaping @Sendable () -> Double?) {
        self.time = time
        cursor.stop()
        cursor = CursorRecorder(area: area, hidden: cursorless, time: time)
        cursor.start()
        events.removeAll()
        windows.removeAll()
        pressed = nil
        lastApp = nil
        take += 1
        checkFrontApp()
        checkWindows()
    }

    func addDrawing(_ tool: LiveDrawTool, color: LiveDrawColor, box: CGRect, tip: CGPoint?) {
        add { .drawing(tool, color: color, box: box, tip: tip, time: $0) }
    }

    func addPin(_ number: Int, at point: CGPoint) {
        add { .pin(number, at: point, time: $0) }
    }

    private func add(_ make: (Double) -> RecordingEvent) {
        guard let now = time() else { return }
        events.append(make(now))
    }

    // MARK: Clicks

    /// The left click in progress: its event and where it went down, to turn it into a drag when it moves.
    private var pressed: (index: Int, point: CGPoint)?

    /// A point in global Cocoa coordinates, in points from the top-left corner of the area.
    private func local(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - area.minX, y: area.maxY - location.y)
    }

    private func mouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            cursor.press(down: true)
            click(.left)
        case .rightMouseDown:
            click(.right)
        case .leftMouseUp:
            cursor.press(down: false)
            mouseUp()
        default:
            break
        }
    }

    private func click(_ button: MouseButton) {
        let location = NSEvent.mouseLocation
        guard area.contains(location), let now = time() else { return }
        let point = local(location)
        events.append(.click(at: point, button: button, time: now))
        pressed = button == .left ? (events.count - 1, point) : nil
        guard Permission.accessibility.isGranted else { return }
        let index = events.count - 1, take = self.take
        // Accessibility asks the clicked app, which is busy with the click: never on the main thread.
        let global = CGPoint(x: location.x, y: CaptureTarget.primaryHeight - location.y)
        Task.detached {
            guard let name = Self.element(at: global) else { return }
            await MainActor.run {
                guard self.take == take, index < self.events.count,
                      case .click(let point, let button, nil) = self.events[index].action else { return }
                self.events[index].action = .click(point, button, element: name)
            }
        }
    }

    /// A press that moved more than 12 points before it was let go was a drag: its click becomes one.
    private func mouseUp() {
        guard let pressed, pressed.index < events.count else { return }
        self.pressed = nil
        let end = local(NSEvent.mouseLocation)
        guard hypot(end.x - pressed.point.x, end.y - pressed.point.y) > 12, let now = time(),
              case .click(let start, _, let element) = events[pressed.index].action else { return }
        events[pressed.index].action = .drag(from: start, to: CGPoint(x: end.x.rounded(), y: end.y.rounded()), until: now, element: element)
    }

    // MARK: Scrolls

    /// Scrolling over the area. Wheel events less than 0.6 s apart are one scroll, which ends at the last of them.
    private func scroll(_ delta: CGVector) {
        let location = NSEvent.mouseLocation
        guard delta != .zero, area.contains(location), let now = time() else { return }
        if let index = events.indices.last, case .scroll(let point, let direction, let until) = events[index].action, now - until < 0.6 {
            events[index].action = .scroll(at: point, direction, until: now)
            return
        }
        let direction: ScrollDirection = abs(delta.dy) >= abs(delta.dx) ? (delta.dy < 0 ? .down : .up) : (delta.dx < 0 ? .right : .left)
        events.append(.scroll(at: local(location), direction, time: now))
    }

    /// `button "Save"`: the role and the title or description of the element at a point in global top-left
    /// coordinates. Never its value, which may be typed text.
    nonisolated static func element(at point: CGPoint) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        return describe(role: string(kAXRoleDescriptionAttribute) ?? string(kAXRoleAttribute),
                        name: string(kAXTitleAttribute) ?? string(kAXDescriptionAttribute))
    }

    /// `button "Save"`, `button`, or nil when there is nothing to say. Long names are cut at 80 characters.
    nonisolated static func describe(role: String?, name: String?) -> String? {
        var role = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if role.hasPrefix("AX") { role = String(role.dropFirst(2)).lowercased() }
        var name = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") ?? ""
        if name.count > 80 { name = String(name.prefix(80)) + "…" }
        let parts = [role, name.isEmpty ? "" : "\"\(name)\""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Apps

    /// Adds an event when the frontmost app or its front window changed. Screenme itself is not an app switch.
    private func checkFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName else { return }
        let window = Self.frontWindowTitle(of: app.processIdentifier)
        if let lastApp, lastApp.app == name, lastApp.window == window { return }
        guard let now = time() else { return }
        lastApp = (name, window)
        events.append(.app(name, window: window, time: now))
    }

    // MARK: Windows

    /// Stores the windows over the area when they changed since the last look.
    private func checkWindows() {
        guard recordsWindows, let now = time() else { return }
        let found = Self.windows(over: area)
        if found == windows.last?.windows { return }
        windows.append(WindowSnapshot(time: now, windows: found))
    }

    /// The normal windows of other apps that overlap `area`, front to back, in points from its top-left corner.
    private static func windows(over area: CGRect) -> [WindowSnapshot.Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        let top = area.cocoaFlipped
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer] as? Int == 0, info[kCGWindowOwnerPID] as? pid_t != own,
                  let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 50, bounds.height >= 50, bounds.intersects(top) else { return nil }
            let title = info[kCGWindowName] as? String
            return WindowSnapshot.Window(app: info[kCGWindowOwnerName] as? String ?? "an app", title: title?.isEmpty == false ? title : nil,
                                         x: (bounds.minX - top.minX).rounded(), y: (bounds.minY - top.minY).rounded(),
                                         width: bounds.width.rounded(), height: bounds.height.rounded())
        }
    }

    private static func frontWindowTitle(of pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let title = list.first { $0[kCGWindowLayer] as? Int == 0 && $0[kCGWindowOwnerPID] as? pid_t == pid }?[kCGWindowName] as? String
        return title?.isEmpty == false ? title : nil
    }
}
