import AppKit
import CoreImage

/// The recorded cursor as a smooth path: resampled at an even 60 Hz, then smoothed forwards and backwards, so it
/// glides without lagging behind the real pointer. Unit coordinates of the video, from the top-left.
struct CursorPath {
    static let rate = 60.0
    /// The smoothing's time constant, in seconds.
    static let smoothing = 0.05

    /// Time of the first sample.
    let start: Double
    let points: [CGPoint]

    init?(track: CursorTrack, width: Double, height: Double) {
        guard !track.isEmpty, width > 0, height > 0 else { return nil }
        start = track.t[0]
        let resampled = Self.resample(times: track.t, xs: track.x.map { $0 / width }, ys: track.y.map { $0 / height }, rate: Self.rate)
        points = Self.smooth(resampled, timeConstant: Self.smoothing, rate: Self.rate)
    }

    func position(at time: Double) -> CGPoint {
        let position = min(max((time - start) * Self.rate, 0), Double(points.count - 1))
        let index = Int(position)
        let next = min(index + 1, points.count - 1)
        let f = position - Double(index)
        return CGPoint(x: points[index].x + (points[next].x - points[index].x) * f,
                       y: points[index].y + (points[next].y - points[index].y) * f)
    }

    /// Positions every 1/`rate` s from the first sample to the last, linearly between samples.
    static func resample(times: [Double], xs: [Double], ys: [Double], rate: Double) -> [CGPoint] {
        guard let first = times.first, let last = times.last else { return [] }
        let count = Int(((last - first) * rate).rounded(.down)) + 1
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = first + Double(i) / rate
            while j + 1 < times.count - 1, times[j + 1] <= t { j += 1 }
            let k = min(j + 1, times.count - 1)
            let span = times[k] - times[j]
            let f = span > 0 ? min(max((t - times[j]) / span, 0), 1) : 0
            result.append(CGPoint(x: xs[j] + (xs[k] - xs[j]) * f, y: ys[j] + (ys[k] - ys[j]) * f))
        }
        return result
    }

    /// Exponential smoothing run forwards then backwards: no lag, no overshoot.
    static func smooth(_ points: [CGPoint], timeConstant: Double, rate: Double) -> [CGPoint] {
        guard points.count > 2, timeConstant > 0 else { return points }
        let a = 1 - exp(-1 / (rate * timeConstant))
        var result = points
        for i in 1..<result.count {
            result[i].x = result[i - 1].x + (result[i].x - result[i - 1].x) * a
            result[i].y = result[i - 1].y + (result[i].y - result[i - 1].y) * a
        }
        for i in stride(from: result.count - 2, through: 0, by: -1) {
            result[i].x = result[i + 1].x + (result[i].x - result[i + 1].x) * a
            result[i].y = result[i + 1].y + (result[i].y - result[i + 1].y) * a
        }
        return result
    }
}
