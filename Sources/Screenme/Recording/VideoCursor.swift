import AppKit
import CoreImage

extension Pref {
    static let videoCursorShow = PrefKey(name: "videoCursorShow", defaultValue: true)
    static let videoCursorSize = PrefKey(name: "videoCursorSize", defaultValue: 1.5)
    static let videoCursorClicks = PrefKey(name: "videoCursorClicks", defaultValue: true)
    static let videoCursorHideIdle = PrefKey(name: "videoCursorHideIdle", defaultValue: false)
}

/// How the editor draws the cursor of a recording made with Smooth cursor.
struct CursorStyle: Codable, Equatable {
    var show = true
    /// 1x is the size it had on screen.
    var size = 1.5
    var clickHighlight = true
    var hideWhenIdle = false

    static let sizeRange = 1.0...3.0

    static var saved: CursorStyle {
        get {
            CursorStyle(show: Prefs[Pref.videoCursorShow],
                        size: min(max(Prefs[Pref.videoCursorSize], sizeRange.lowerBound), sizeRange.upperBound),
                        clickHighlight: Prefs[Pref.videoCursorClicks], hideWhenIdle: Prefs[Pref.videoCursorHideIdle])
        }
        set {
            Prefs[Pref.videoCursorShow] = newValue.show
            Prefs[Pref.videoCursorSize] = newValue.size
            Prefs[Pref.videoCursorClicks] = newValue.clickHighlight
            Prefs[Pref.videoCursorHideIdle] = newValue.hideWhenIdle
        }
    }
}

/// Draws the smooth cursor onto a source frame: the arrow at the smoothed position, the click highlight of
/// the recording controls (a yellow disc that springs in on press and grows and fades on release), and an
/// optional fade when the pointer rests. Everything is prepared once; a frame only moves small images.
final class CursorOverlay: @unchecked Sendable {
    /// After this long without moving, Hide when idle fades the cursor out.
    static let idleDelay = 2.0
    static let fadeOut = 0.3
    static let fadeIn = 0.12
    /// The highlight's timing, as in `RecordingEffects`.
    static let pressGrow = 0.25
    static let releaseFade = 0.32

    let path: CursorPath
    /// The arrow, its hotspot at the origin.
    private let arrow: CIImage
    /// The highlight disc, centered at the origin; nil when click highlights are off.
    private let ripple: CIImage?
    private let presses: [(down: Double, up: Double)]
    /// 60 Hz opacity from `path.start`; nil when the cursor never hides.
    private let opacity: [Double]?

    /// `pixelsPerPoint` is video pixels per screen point.
    @MainActor
    init(path: CursorPath, track: CursorTrack, style: CursorStyle, pixelsPerPoint: CGFloat) {
        self.path = path
        arrow = Self.arrowImage(scale: pixelsPerPoint * style.size)
        ripple = style.clickHighlight ? Self.rippleImage(radius: 26 * pixelsPerPoint) : nil
        presses = Self.pair(downs: track.down, ups: track.up)
        opacity = style.hideWhenIdle ? Self.idleOpacity(path: path, presses: track.down) : nil
    }

    /// `source` with the cursor drawn at `time` (seconds of the recording).
    func draw(over source: CIImage, at time: Double) -> CIImage {
        let extent = source.extent
        let unit = path.position(at: time)
        let point = CGPoint(x: extent.minX + unit.x * extent.width, y: extent.minY + (1 - unit.y) * extent.height)
        var alpha = 1.0
        if let opacity {
            let index = min(max(Int(((time - path.start) * CursorPath.rate).rounded()), 0), opacity.count - 1)
            alpha = opacity[index]
        }
        var image = source
        if let ripple, let (scale, rippleAlpha) = highlight(at: time) {
            let disc = ripple.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
            image = Self.faded(disc, rippleAlpha).composited(over: image)
        }
        guard alpha > 0.01 else { return image.cropped(to: extent) }
        let cursor = arrow.transformed(by: CGAffineTransform(translationX: point.x, y: point.y))
        return Self.faded(cursor, alpha).composited(over: image).cropped(to: extent)
    }

    /// The highlight's scale and opacity at `time`, or nil when no press shows.
    func highlight(at time: Double) -> (scale: Double, alpha: Double)? {
        guard let press = presses.last(where: { $0.down <= time }) else { return nil }
        if time < press.up {
            let p = min((time - press.down) / Self.pressGrow, 1)
            return (0.35 + 0.65 * CameraPath.ease(p), 1)
        }
        let p = (time - press.up) / Self.releaseFade
        guard p < 1 else { return nil }
        let eased = 1 - (1 - p) * (1 - p)
        return (1 + 0.7 * eased, 1 - eased)
    }

    /// Each press with its release: the first release after it, or a short tap when none was recorded.
    static func pair(downs: [Double], ups: [Double]) -> [(down: Double, up: Double)] {
        downs.sorted().map { down in (down, ups.first { $0 >= down } ?? down + 0.1) }
    }

    /// 1 while the pointer moves or was pressed in the last `idleDelay` seconds, fading to 0 after that.
    static func idleOpacity(path: CursorPath, presses: [Double]) -> [Double] {
        let dt = 1 / CursorPath.rate
        let pressSamples = Set(presses.map { Int((($0 - path.start) * CursorPath.rate).rounded()) })
        var result: [Double] = []
        result.reserveCapacity(path.points.count)
        var lastActive = 0.0
        var current = 1.0
        for (i, point) in path.points.enumerated() {
            let time = Double(i) * dt
            if i > 0 {
                let previous = path.points[i - 1]
                if hypot(point.x - previous.x, point.y - previous.y) > 0.0005 || pressSamples.contains(i) { lastActive = time }
            }
            let target = 1 - min(max((time - lastActive - idleDelay) / fadeOut, 0), 1)
            current = target > current ? min(target, current + dt / fadeIn) : target
            result.append(current)
        }
        return result
    }

    private static func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    /// The system arrow at `scale` pixels per point, drawn from its best representation, hotspot at the origin.
    @MainActor
    private static func arrowImage(scale: CGFloat) -> CIImage {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        let width = max(Int((size.width * scale).rounded(.up)), 1), height = max(Int((size.height * scale).rounded(.up)), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        cursor.image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return CIImage.empty() }
        // The hotspot is measured from the top-left; Core Image's origin is the bottom-left.
        let hot = cursor.hotSpot
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: -hot.x * scale, y: -(size.height - hot.y) * scale))
    }

    /// The click highlight of the recording controls: a yellow disc with a stronger rim, centered at the origin.
    private static func rippleImage(radius: CGFloat) -> CIImage? {
        let side = Int((radius * 2 + 4).rounded(.up))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let line = 2.5 * radius / 26
        let rect = CGRect(x: 2, y: 2, width: radius * 2, height: radius * 2).insetBy(dx: line / 2, dy: line / 2)
        let tint = NSColor.systemYellow.usingColorSpace(.sRGB) ?? .yellow
        ctx.setFillColor(tint.withAlphaComponent(0.38).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(tint.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: rect)
        guard let image = ctx.makeImage() else { return nil }
        let half = CGFloat(side) / 2
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: -half, y: -half))
    }
}

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
