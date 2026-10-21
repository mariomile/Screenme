import AppKit
import ApplicationServices

/// Something that happened during a recording, at a time in seconds of the finished video.
/// Positions are points from the top-left corner of the recorded area.
struct RecordingEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case click, drag, scroll, shortcut, app, drawing
    }

    struct Box: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var time: Double
    var kind: Kind
    /// Click: where. Drag: where it started. Scroll: where the pointer was. Arrow: where it points.
    var x: Double?
    var y: Double?
    /// Drag: where it was let go.
    var toX: Double?
    var toY: Double?
    /// Drag and scroll: when it ended, in seconds of the video.
    var until: Double?
    /// Scroll: "down" (further down the page), "up", "left" or "right".
    var direction: String?
    /// Click: "right" for a right click, nil for a left one.
    var button: String?
    /// Click: the element under the pointer, `button "Save"`, when Accessibility is allowed.
    var element: String?
    /// Shortcut: "⌘S", "Return".
    var keys: String?
    /// App switch: the frontmost app and its front window.
    var app: String?
    var window: String?
    /// Drawing: the tool, its color and the area it covers.
    var tool: String?
    var color: String?
    var box: Box?

    static func click(at point: CGPoint, right: Bool, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .click, x: point.x.rounded(), y: point.y.rounded(), button: right ? "right" : nil)
    }

    static func scroll(at point: CGPoint, direction: String, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .scroll, x: point.x.rounded(), y: point.y.rounded(), until: time, direction: direction)
    }

    static func shortcut(_ keys: String, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .shortcut, keys: keys)
    }

    static func app(_ app: String, window: String?, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .app, app: app, window: window)
    }

    static func drawing(_ tool: LiveDrawTool, color: LiveDrawColor, box: CGRect, tip: CGPoint?, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .drawing, x: tip.map { $0.x.rounded() }, y: tip.map { $0.y.rounded() },
                       tool: tool.rawValue, color: color.rawValue,
                       box: Box(x: box.minX.rounded(), y: box.minY.rounded(), width: box.width.rounded(), height: box.height.rounded()))
    }
}

/// The on-screen windows over the recorded area at one time, front to back, for cropping keyframes.
struct WindowSnapshot: Codable, Equatable {
    struct Window: Codable, Equatable {
        var app: String
        var title: String?
        /// Points from the top-left corner of the recorded area; may reach outside it.
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    var time: Double
    var windows: [Window]
}

/// Everything recorded during one recording: the size of the recorded area and the events in time order.
/// Kept in memory by recording file, and next to it as a hidden JSON file so a report made later still finds it.
struct RecordingEvents: Codable, Equatable {
    var width: Double
    var height: Double
    var events: [RecordingEvent]
    /// Display and area recordings: the windows over the area, stored when they changed, about once a second.
    var windows: [WindowSnapshot]?
    /// Where the pointer was, `[time, x, y]` in points from the top-left corner of the area, about 20 times a second
    /// while it moves inside the area.
    var cursor: [[Double]]?

    /// `.Screenme 2026-10-21 at 10.22.33.mp4.events.json` next to the recording. Hidden, so neither History
    /// nor the command line's capture list ever shows it as a capture.
    static func sidecarURL(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".\(video.lastPathComponent).events.json")
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Store

    @MainActor private static var recorded: [URL: RecordingEvents] = [:]

    @MainActor
    static func record(_ events: RecordingEvents, for video: URL) {
        recorded[video] = events
        try? events.json().write(to: sidecarURL(for: video), options: .atomic)
    }

    /// The events of a recording, from memory or from its sidecar. Nil for recordings made without them.
    @MainActor
    static func events(for video: URL) -> RecordingEvents? {
        if let events = recorded[video] { return events }
        guard let data = try? Data(contentsOf: sidecarURL(for: video)) else { return nil }
        return try? JSONDecoder().decode(RecordingEvents.self, from: data)
    }

    /// The recording went to the Trash: its events go too.
    @MainActor
    static func forget(_ video: URL) {
        recorded[video] = nil
        try? FileManager.default.removeItem(at: sidecarURL(for: video))
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
/// allowed), shortcuts, app and window switches, and drawings. `time` gives the video time of now, nil while paused.
@MainActor
final class RecordingEventRecorder {
    private let area: CGRect
    private let recordsWindows: Bool
    private let time: () -> Double?
    private(set) var events: [RecordingEvent] = []
    private var windows: [WindowSnapshot] = []
    private var cursor: [[Double]] = []
    private var monitors: [Any] = []
    private var poll: Timer?
    private var cursorPoll: Timer?
    private var lastApp: (app: String, window: String?)?
    /// Bumped by `reset`, so an element name looked up for a thrown-away take is not added to the new one.
    private var take = 0

    /// `area` is the recorded area in global Cocoa coordinates. `recordsWindows` (display and area recordings) also
    /// records the windows over it and the pointer, so the report can crop each keyframe to where things happened.
    init(area: CGRect, recordsWindows: Bool, time: @escaping () -> Double?) {
        self.area = area
        self.recordsWindows = recordsWindows
        self.time = time
    }

    var recorded: RecordingEvents {
        RecordingEvents(width: area.width, height: area.height, events: events.sorted { $0.time < $1.time },
                        windows: recordsWindows ? windows : nil, cursor: recordsWindows ? cursor : nil)
    }

    func start() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.click(right: right) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
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
        if recordsWindows {
            cursorPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkCursor() }
            }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        poll?.invalidate()
        poll = nil
        cursorPoll?.invalidate()
        cursorPoll = nil
    }

    /// A restart: the events so far belong to the take that was thrown away.
    func reset() {
        events.removeAll()
        windows.removeAll()
        cursor.removeAll()
        pressed = nil
        lastApp = nil
        take += 1
        checkFrontApp()
        checkWindows()
    }

    func addDrawing(_ tool: LiveDrawTool, color: LiveDrawColor, box: CGRect, tip: CGPoint?) {
        add { .drawing(tool, color: color, box: box, tip: tip, time: $0) }
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

    private func click(right: Bool) {
        let location = NSEvent.mouseLocation
        guard area.contains(location), let now = time() else { return }
        let point = local(location)
        events.append(.click(at: point, right: right, time: now))
        pressed = right ? nil : (events.count - 1, point)
        guard Permission.accessibility.isGranted else { return }
        let index = events.count - 1, take = self.take
        // Accessibility asks the clicked app, which is busy with the click: never on the main thread.
        let global = CGPoint(x: location.x, y: CaptureTarget.primaryHeight - location.y)
        Task.detached {
            guard let name = Self.element(at: global) else { return }
            await MainActor.run {
                guard self.take == take, index < self.events.count else { return }
                self.events[index].element = name
            }
        }
    }

    /// A press that moved more than 12 points before it was let go was a drag: its click becomes one.
    private func mouseUp() {
        guard let pressed, pressed.index < events.count else { return }
        self.pressed = nil
        let end = local(NSEvent.mouseLocation)
        guard hypot(end.x - pressed.point.x, end.y - pressed.point.y) > 12, let now = time() else { return }
        events[pressed.index].kind = .drag
        events[pressed.index].toX = end.x.rounded()
        events[pressed.index].toY = end.y.rounded()
        events[pressed.index].until = now
    }

    // MARK: Scrolls

    /// Scrolling over the area. Wheel events less than 0.6 s apart are one scroll, which ends at the last of them.
    private func scroll(_ delta: CGVector) {
        let location = NSEvent.mouseLocation
        guard delta != .zero, area.contains(location), let now = time() else { return }
        if let index = events.indices.last, events[index].kind == .scroll, now - (events[index].until ?? events[index].time) < 0.6 {
            events[index].until = now
            return
        }
        let direction = abs(delta.dy) >= abs(delta.dx) ? (delta.dy < 0 ? "down" : "up") : (delta.dx < 0 ? "right" : "left")
        events.append(.scroll(at: local(location), direction: direction, time: now))
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

    // MARK: Windows and pointer

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

    /// Adds the pointer when it moved inside the area.
    private func checkCursor() {
        let location = NSEvent.mouseLocation
        guard area.contains(location), let now = time() else { return }
        let point = local(location)
        if let last = cursor.last, abs(last[1] - point.x) < 1, abs(last[2] - point.y) < 1 { return }
        cursor.append([(now * 100).rounded() / 100, point.x.rounded(), point.y.rounded()])
    }

    private static func frontWindowTitle(of pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let title = list.first { $0[kCGWindowLayer] as? Int == 0 && $0[kCGWindowOwnerPID] as? pid_t == pid }?[kCGWindowName] as? String
        return title?.isEmpty == false ? title : nil
    }
}
