import AppKit
import ApplicationServices

/// Something that happened during a recording, at a time in seconds of the finished video.
/// Positions are points from the top-left corner of the recorded area.
struct RecordingEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case click, shortcut, app, drawing
    }

    struct Box: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var time: Double
    var kind: Kind
    /// Click: where. Arrow: where it points.
    var x: Double?
    var y: Double?
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

/// Everything recorded during one recording: the size of the recorded area and the events in time order.
/// Kept in memory by recording file, and next to it as a hidden JSON file so a report made later still finds it.
struct RecordingEvents: Codable, Equatable {
    var width: Double
    var height: Double
    var events: [RecordingEvent]
    /// The pointer's path and button presses, for the video editor's zoom and Smooth cursor. Nil in older recordings.
    var cursor: CursorTrack? = nil

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
    private let time: () -> Double?
    private(set) var events: [RecordingEvent] = []
    private var monitors: [Any] = []
    private var poll: Timer?
    private var lastApp: (app: String, window: String?)?
    /// Bumped by `reset`, so an element name looked up for a thrown-away take is not added to the new one.
    private var take = 0

    /// `area` is the recorded area in global Cocoa coordinates.
    init(area: CGRect, time: @escaping () -> Double?) {
        self.area = area
        self.time = time
    }

    var recorded: RecordingEvents {
        RecordingEvents(width: area.width, height: area.height, events: events.sorted { $0.time < $1.time })
    }

    func start() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.click(right: right) }
        }) { monitors.append(monitor) }
        // Key events reach other apps' monitors only with Accessibility.
        if Permission.accessibility.isGranted, let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keys = RecordingEvents.shortcut(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated { if let keys { self?.add { .shortcut(keys, time: $0) } } }
        }) { monitors.append(monitor) }
        checkFrontApp()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontApp() }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        poll?.invalidate()
        poll = nil
    }

    /// A restart: the events so far belong to the take that was thrown away.
    func reset() {
        events.removeAll()
        lastApp = nil
        take += 1
        checkFrontApp()
    }

    func addDrawing(_ tool: LiveDrawTool, color: LiveDrawColor, box: CGRect, tip: CGPoint?) {
        add { .drawing(tool, color: color, box: box, tip: tip, time: $0) }
    }

    private func add(_ make: (Double) -> RecordingEvent) {
        guard let now = time() else { return }
        events.append(make(now))
    }

    // MARK: Clicks

    private func click(right: Bool) {
        let location = NSEvent.mouseLocation
        guard area.contains(location), let now = time() else { return }
        let point = CGPoint(x: location.x - area.minX, y: area.maxY - location.y)
        events.append(.click(at: point, right: right, time: now))
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

    private static func frontWindowTitle(of pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let title = list.first { $0[kCGWindowLayer] as? Int == 0 && $0[kCGWindowOwnerPID] as? pid_t == pid }?[kCGWindowName] as? String
        return title?.isEmpty == false ? title : nil
    }
}
