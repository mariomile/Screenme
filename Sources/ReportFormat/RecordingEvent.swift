import CoreGraphics
import Foundation

/// The tools for drawing on the screen while recording. A pin is a numbered red marker.
enum LiveDrawTool: String, Codable, CaseIterable, Identifiable {
    case pen, arrow, rectangle, highlighter, pin

    var id: String { rawValue }
}

enum LiveDrawColor: String, Codable, CaseIterable, Identifiable {
    case red, yellow, green, blue

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MouseButton: String, Codable {
    case left, right
}

/// Which way a scroll moved the page: `down` shows what is further down.
enum ScrollDirection: String, Codable {
    case up, down, left, right
}

/// Something that happened during a recording, at a time in seconds of the finished video.
/// Positions are points from the top-left corner of the recorded area.
///
/// In JSON (the events sidecar and `report.json`) an event is one flat object: `time`, `kind`, and the fields of its
/// kind (`x`, `y`, `toX`, `toY`, `until`, `direction`, `button`, `element`, `keys`, `app`, `window`, `tool`, `color`,
/// `box`, `number`), as it has always been written.
struct RecordingEvent: Equatable {
    enum Kind: String, Codable {
        case click, drag, scroll, shortcut, app, drawing, pin
    }

    /// An area in points from the top-left corner of the recorded area.
    struct Box: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    enum Action: Equatable {
        /// `element` is the element under the pointer, `button "Save"`, when Accessibility is allowed.
        case click(CGPoint, MouseButton, element: String?)
        /// A left press that moved before it was let go, at `until` seconds.
        case drag(from: CGPoint, to: CGPoint, until: Double, element: String?)
        /// Wheel events close together, the last at `until` seconds.
        case scroll(at: CGPoint, ScrollDirection, until: Double)
        /// "⌘S", "Return".
        case shortcut(String)
        /// The frontmost app and its front window.
        case app(String, window: String?)
        /// A finished drawing, the area it covers and, for an arrow, where it points.
        case drawing(LiveDrawTool, LiveDrawColor, box: Box, tip: CGPoint?)
        /// A numbered pin.
        case pin(Int, at: CGPoint)
    }

    var time: Double
    var action: Action

    var kind: Kind {
        switch action {
        case .click: .click
        case .drag: .drag
        case .scroll: .scroll
        case .shortcut: .shortcut
        case .app: .app
        case .drawing: .drawing
        case .pin: .pin
        }
    }

    /// Where it happened: a click, the start of a drag, the pointer of a scroll, a pin. Nil for the rest.
    var point: CGPoint? {
        switch action {
        case .click(let point, _, _), .drag(let point, _, _, _), .scroll(let point, _, _), .pin(_, let point): point
        case .shortcut, .app, .drawing: nil
        }
    }

    static func click(at point: CGPoint, button: MouseButton = .left, element: String? = nil, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, action: .click(point.rounded, button, element: element))
    }

    static func scroll(at point: CGPoint, _ direction: ScrollDirection, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, action: .scroll(at: point.rounded, direction, until: time))
    }

    static func shortcut(_ keys: String, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, action: .shortcut(keys))
    }

    static func app(_ app: String, window: String?, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, action: .app(app, window: window))
    }

    static func pin(_ number: Int, at point: CGPoint, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, action: .pin(number, at: point.rounded))
    }

    static func drawing(_ tool: LiveDrawTool, color: LiveDrawColor, box: CGRect, tip: CGPoint?, time: Double) -> RecordingEvent {
        let box = Box(x: box.minX.rounded(), y: box.minY.rounded(), width: box.width.rounded(), height: box.height.rounded())
        return RecordingEvent(time: time, action: .drawing(tool, color, box: box, tip: tip?.rounded))
    }
}

extension RecordingEvent: Codable {
    private enum Key: String, CodingKey {
        case time, kind, x, y, toX, toY, until, direction, button, element, keys, app, window, tool, color, box, number
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func point(_ x: Key = .x, _ y: Key = .y) throws -> CGPoint {
            CGPoint(x: try c.decode(Double.self, forKey: x), y: try c.decode(Double.self, forKey: y))
        }
        time = try c.decode(Double.self, forKey: .time)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .click:
            action = .click(try point(), try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left,
                            element: try c.decodeIfPresent(String.self, forKey: .element))
        case .drag:
            action = .drag(from: try point(), to: try point(.toX, .toY), until: try c.decode(Double.self, forKey: .until),
                           element: try c.decodeIfPresent(String.self, forKey: .element))
        case .scroll:
            action = .scroll(at: try point(), try c.decode(ScrollDirection.self, forKey: .direction), until: try c.decode(Double.self, forKey: .until))
        case .shortcut:
            action = .shortcut(try c.decode(String.self, forKey: .keys))
        case .app:
            action = .app(try c.decode(String.self, forKey: .app), window: try c.decodeIfPresent(String.self, forKey: .window))
        case .drawing:
            action = .drawing(try c.decode(LiveDrawTool.self, forKey: .tool), try c.decode(LiveDrawColor.self, forKey: .color),
                              box: try c.decode(Box.self, forKey: .box), tip: try c.contains(.x) ? point() : nil)
        case .pin:
            action = .pin(try c.decode(Int.self, forKey: .number), at: try point())
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        func encode(_ point: CGPoint, _ x: Key = .x, _ y: Key = .y) throws {
            try c.encode(Double(point.x), forKey: x)
            try c.encode(Double(point.y), forKey: y)
        }
        try c.encode(time, forKey: .time)
        try c.encode(kind, forKey: .kind)
        switch action {
        case .click(let point, let button, let element):
            try encode(point)
            // A left click has always been written without a button.
            if button == .right { try c.encode(button, forKey: .button) }
            try c.encodeIfPresent(element, forKey: .element)
        case .drag(let from, let to, let until, let element):
            try encode(from)
            try encode(to, .toX, .toY)
            try c.encode(until, forKey: .until)
            try c.encodeIfPresent(element, forKey: .element)
        case .scroll(let point, let direction, let until):
            try encode(point)
            try c.encode(direction, forKey: .direction)
            try c.encode(until, forKey: .until)
        case .shortcut(let keys):
            try c.encode(keys, forKey: .keys)
        case .app(let app, let window):
            try c.encode(app, forKey: .app)
            try c.encodeIfPresent(window, forKey: .window)
        case .drawing(let tool, let color, let box, let tip):
            try c.encode(tool, forKey: .tool)
            try c.encode(color, forKey: .color)
            try c.encode(box, forKey: .box)
            if let tip { try encode(tip) }
        case .pin(let number, let point):
            try c.encode(number, forKey: .number)
            try encode(point)
        }
    }
}

private extension CGPoint {
    /// Whole points, as events store them.
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
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
