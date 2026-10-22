import CoreGraphics
import Foundation

/// Something that happened during a recording, at a time in seconds of the finished video.
/// Positions are points from the top-left corner of the recorded area.
struct RecordingEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case click, drag, scroll, shortcut, app, drawing, pin
    }

    struct Box: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var time: Double
    var kind: Kind
    /// Click: where. Drag: where it started. Scroll: where the pointer was. Arrow: where it points. Pin: where it is.
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
    /// Pin: its number on screen.
    var number: Int?

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

    static func pin(_ number: Int, at point: CGPoint, time: Double) -> RecordingEvent {
        RecordingEvent(time: time, kind: .pin, x: point.x.rounded(), y: point.y.rounded(), number: number)
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
