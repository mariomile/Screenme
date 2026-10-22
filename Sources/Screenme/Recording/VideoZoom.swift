import CoreGraphics
import Foundation

/// A stretch of the video shown zoomed in. Positions are unit coordinates of the video, from the top-left.
struct ZoomSegment: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var center: CGPoint
    /// How far in; nil follows the Auto zoom strength.
    var zoom: Double?
    /// Made from clicks, and follows the cursor. A zoom added by hand stays on the region picked for it.
    var isAuto: Bool

    var duration: Double { end - start }
}

/// Zoom segments from the clicks of a recording.
enum AutoZoom {
    /// The zoom starts this long before a click and ends this long after the last click of a run.
    static let lead = 1.5
    static let tail = 2.0
    /// Clicks closer than this share one zoom.
    static let mergeGap = 3.0
    static let strengthRange = 1.3...3.0
    /// A click this long before, or this long after, an app or window switch is part of the switch: no zoom.
    static let switchAfterClick = 1.0
    static let switchBeforeClick = 0.5
    /// Shorter segments, cut by the start or end of the video, are left out.
    static let shortest = 0.5

    static func segments(for events: RecordingEvents, duration: Double) -> [ZoomSegment] {
        let width = max(events.width, 1), height = max(events.height, 1)
        let clicks = events.events.compactMap { event -> (Double, CGPoint)? in
            guard case .click(let point, _, _) = event.action else { return nil }
            return (event.time, CGPoint(x: point.x / width, y: point.y / height))
        }
        // The first app event is where the recording started, not a switch.
        let switches = events.events.filter { $0.kind == .app && $0.time > 0.1 }.map(\.time)
        return segments(clicks: clicks, switches: switches, duration: duration)
    }

    static func segments(clicks: [(time: Double, point: CGPoint)], switches: [Double], duration: Double) -> [ZoomSegment] {
        let kept = clicks
            .filter { click in !switches.contains { $0 >= click.time - switchBeforeClick && $0 <= click.time + switchAfterClick } }
            .sorted { $0.time < $1.time }

        // Runs of clicks less than `mergeGap` apart.
        var runs: [(first: Double, last: Double, point: CGPoint)] = []
        for click in kept {
            if let last = runs.last, click.time - last.last < mergeGap {
                runs[runs.count - 1].last = click.time
            } else {
                runs.append((click.time, click.time, click.point))
            }
        }

        var segments: [ZoomSegment] = []
        for run in runs {
            let start = max(0, run.first - lead), end = min(duration, run.last + tail)
            if let last = segments.last, start <= last.end {
                segments[segments.count - 1].end = max(last.end, end)
            } else {
                segments.append(ZoomSegment(start: start, end: end, center: run.point, isAuto: true))
            }
        }
        return segments.filter { $0.duration >= shortest }
    }
}

/// What the camera shows at one moment: how far in, and around which point (unit coordinates, from the top-left).
struct Camera: Equatable {
    var zoom: Double
    var center: CGPoint

    static let full = Camera(zoom: 1, center: CGPoint(x: 0.5, y: 0.5))

    /// The part of the video in view, in unit coordinates from the top-left. Never past the video's edges.
    var visibleRect: CGRect {
        let size = 1 / max(zoom, 1)
        let x = min(max(center.x - size / 2, 0), 1 - size)
        let y = min(max(center.y - size / 2, 0), 1 - size)
        return CGRect(x: x, y: y, width: size, height: size)
    }
}

/// The camera over the whole video, worked out once at 60 Hz so any frame can be drawn on its own, in any order.
/// Inside a segment the zoom eases in and out on a spring-like curve; an automatic zoom follows the cursor
/// softly: it moves only when the cursor leaves a dead zone in the middle of the view, and then smoothly.
struct CameraPath {
    static let rate = 60.0
    /// How long the zoom takes to ease in, and out, at most.
    static let ramp = 0.8
    /// The share of the view, around its center, the cursor moves in without moving the camera.
    static let deadZone = 0.5
    /// How quickly the camera catches up with where it should look, in seconds.
    static let followTime = 0.35

    private let samples: [Camera]

    init(segments: [ZoomSegment], strength: Double, cursor: CursorPath?, duration: Double) {
        let count = max(Int((duration * Self.rate).rounded(.up)) + 1, 1)
        let dt = 1 / Self.rate
        let smoothing = 1 - exp(-dt / Self.followTime)
        var samples: [Camera] = []
        samples.reserveCapacity(count)
        var focus = CGPoint(x: 0.5, y: 0.5)
        var active: UUID?
        for index in 0..<count {
            let time = Double(index) * dt
            guard let segment = segments.last(where: { time >= $0.start && time <= $0.end }) else {
                active = nil
                samples.append(Camera(zoom: 1, center: focus))
                continue
            }
            let full = min(max(segment.zoom ?? strength, 1), AutoZoom.strengthRange.upperBound)
            if active != segment.id {
                active = segment.id
                // Fully zoomed out, the center does not show: start from the segment's own point.
                if samples.last.map({ $0.zoom < 1.001 }) ?? true { focus = segment.center }
            }
            var target = segment.center
            if segment.isAuto, let cursor {
                target = Self.follow(focus: focus, cursor: cursor.position(at: time), viewSize: 1 / full)
            }
            focus.x += (target.x - focus.x) * smoothing
            focus.y += (target.y - focus.y) * smoothing
            samples.append(Camera(zoom: 1 + (full - 1) * Self.envelope(segment, at: time), center: focus))
        }
        self.samples = samples
    }

    func camera(at time: Double) -> Camera {
        guard !samples.isEmpty else { return .full }
        let position = min(max(time * Self.rate, 0), Double(samples.count - 1))
        let index = Int(position)
        let next = min(index + 1, samples.count - 1)
        let f = position - Double(index)
        let a = samples[index], b = samples[next]
        return Camera(zoom: a.zoom + (b.zoom - a.zoom) * f,
                      center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * f, y: a.center.y + (b.center.y - a.center.y) * f))
    }

    /// Where the camera should look so `cursor` stays inside the dead zone of a view `viewSize` wide (unit coordinates).
    static func follow(focus: CGPoint, cursor: CGPoint, viewSize: Double) -> CGPoint {
        let half = viewSize * deadZone / 2
        func axis(_ f: Double, _ c: Double) -> Double {
            if c > f + half { return c - half }
            if c < f - half { return c + half }
            return f
        }
        return CGPoint(x: axis(focus.x, cursor.x), y: axis(focus.y, cursor.y))
    }

    /// 0 outside the segment, rising to 1 after the ramp and falling back to 0 at its end.
    static func envelope(_ segment: ZoomSegment, at time: Double) -> Double {
        guard time >= segment.start, time <= segment.end else { return 0 }
        let ramp = min(Self.ramp, segment.duration / 2)
        guard ramp > 0 else { return 0 }
        return min(ease((time - segment.start) / ramp), ease((segment.end - time) / ramp))
    }

    /// A critically damped spring settling from 0 to 1 over x in 0...1: starts slowly, lands softly.
    static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        let k = 7.0
        let spring = { (t: Double) in 1 - (1 + k * t) * exp(-k * t) }
        return spring(x) / spring(1)
    }
}
