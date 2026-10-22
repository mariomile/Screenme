import AppKit
import CoreGraphics

extension Pref {
    /// Records without the cursor in the picture and lets the video editor draw a smooth one from the cursor track.
    static let recordingSmoothCursor = PrefKey(name: "recordingSmoothCursor", defaultValue: false)
}

/// Where the pointer was during a recording, sampled at 60 Hz, and when the left button went down and up.
/// Times are seconds of the finished video; positions are points from the top-left corner of the recorded area,
/// like the other events. A still pointer adds no samples: a run of equal positions keeps only its first and last.
struct CursorTrack: Codable, Equatable {
    /// True when the recording was filmed without the cursor (Smooth cursor). Stays true after the cursor is drawn in.
    var hidden: Bool
    /// The style the cursor was drawn into the capture with when the recording stopped (`BakedCursor`). Nil when
    /// nothing was drawn in: the capture is the raw recording.
    var bakedStyle: CursorStyle? = nil
    var t: [Double] = []
    var x: [Double] = []
    var y: [Double] = []
    /// Left button presses and releases.
    var down: [Double] = []
    var up: [Double] = []

    var isEmpty: Bool { t.isEmpty }

    /// Whether the capture these events belong to shows the cursor: filmed with it, or drawn in since.
    var isInPicture: Bool { !hidden || bakedStyle != nil }

    /// Adds a sample. A sample at the same position as the previous one only moves the end of the still run.
    mutating func add(time: Double, x px: Double, y py: Double) {
        let time = (time * 1000).rounded() / 1000
        let px = (px * 10).rounded() / 10, py = (py * 10).rounded() / 10
        if let last = t.indices.last, time <= t[last] { return }
        let count = t.count
        if count >= 2, x[count - 1] == px, y[count - 1] == py, x[count - 2] == px, y[count - 2] == py {
            t[count - 1] = time
            return
        }
        t.append(time)
        x.append(px)
        y.append(py)
    }
}

/// Samples the pointer 60 times a second on a background queue while a recording runs, with the left button
/// presses `RecordingEventRecorder` hands it. `time` is the recorder's pause-aware clock: nil while paused, so
/// paused time adds nothing.
@MainActor
final class CursorRecorder {
    private let sampler: CursorSampler

    /// `area` is the recorded area in global Cocoa coordinates.
    init(area: CGRect, hidden: Bool, time: @escaping @Sendable () -> Double?) {
        // Global top-left coordinates, which is what CGEvent reports.
        let top = CaptureTarget.primaryHeight - area.maxY
        sampler = CursorSampler(origin: CGPoint(x: area.minX, y: top), hidden: hidden, time: time)
    }

    var track: CursorTrack { sampler.track }

    func start() { sampler.start() }

    func stop() { sampler.stop() }

    /// The left button went down or up.
    func press(down: Bool) { sampler.press(down: down) }
}

/// The queue-confined half of `CursorRecorder`.
private final class CursorSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mariomiletta.screenme.cursor", qos: .utility)
    private let origin: CGPoint
    private let hidden: Bool
    private let time: @Sendable () -> Double?
    private var timer: DispatchSourceTimer?
    private var current: CursorTrack

    init(origin: CGPoint, hidden: Bool, time: @escaping @Sendable () -> Double?) {
        self.origin = origin
        self.hidden = hidden
        self.time = time
        current = CursorTrack(hidden: hidden)
    }

    var track: CursorTrack { queue.sync { current } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            sample()
        }
    }

    func press(down: Bool) {
        queue.async {
            guard let now = self.time() else { return }
            let rounded = (now * 1000).rounded() / 1000
            if down { self.current.down.append(rounded) } else if !self.current.down.isEmpty { self.current.up.append(rounded) }
        }
    }

    private func sample() {
        guard let location = CGEvent(source: nil)?.location, let now = time() else { return }
        current.add(time: now, x: location.x - origin.x, y: location.y - origin.y)
    }
}
