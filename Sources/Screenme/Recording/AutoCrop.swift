import CoreGraphics
import Foundation

extension Pref {
    /// Report for AI crops each keyframe of a display or area recording to the window where things happened.
    static let reportAutoCrop = PrefKey(name: "reportAutoCrop", defaultValue: true)
}

/// Auto-crop for display and area recordings: each keyframe cut down to the window holding the activity at that
/// moment, so an agent reads it without hunting across a whole screen. A pure function of the recorded events,
/// windows and pointer, unit tested; `AIReporter` cuts the pictures.
enum AutoCrop {
    /// A keyframe's crop in points from the top-left corner of the recorded area, and the apps it shows.
    struct Crop: Equatable {
        var rect: CGRect
        var apps: [String]
    }

    static let padding: CGFloat = 24
    static let minWidth: CGFloat = 480
    /// A crop covering more than this share of the area is not worth it: the keyframe stays whole.
    static let maxShare: CGFloat = 0.8
    /// Neighbouring crops that overlap by this much of the smaller one become one, so the sheet does not jitter.
    static let mergeOverlap: CGFloat = 0.6

    /// Something that happened at a place, and how much it says about where the user was working.
    struct Activity: Equatable {
        var point: CGPoint
        var weight: Double
        /// Ink, pins, clicks, drags and scrolls: the crop always shows them.
        var strong: Bool { weight >= 3 }
    }

    /// One crop per keyframe, nil for a keyframe that stays whole. Nil everywhere without recorded windows.
    static func crops(for keyframes: [Keyframe], events: RecordingEvents) -> [Crop?] {
        guard let snapshots = events.windows, !snapshots.isEmpty else { return keyframes.map { _ in nil } }
        let area = CGRect(x: 0, y: 0, width: events.width, height: events.height)
        var crops: [Crop?] = []
        for (index, keyframe) in keyframes.enumerated() {
            let from = index == 0 ? -Double.infinity : (keyframes[index - 1].time + keyframe.time) / 2
            let to = index == keyframes.count - 1 ? Double.infinity : (keyframe.time + keyframes[index + 1].time) / 2
            let windows = (snapshots.last { $0.time <= keyframe.time } ?? snapshots[0]).windows
            let activity = activity(from: from, to: to, in: events)
            // Only talk: the crop of the keyframe before.
            crops.append(crop(activity, windows: windows, area: area) ?? (activity.isEmpty ? crops.last ?? nil : nil))
        }
        return merged(crops, area: area)
    }

    /// What happened between `from` and `to`: ink and pins, clicks and drags, scrolls, and where the pointer rested
    /// inside the area (weighed by the seconds it stayed, at most 2 a place), from the cursor track.
    static func activity(from: Double, to: Double, in events: RecordingEvents) -> [Activity] {
        var found: [Activity] = []
        for event in events.events where event.time >= from && event.time < to {
            switch event.action {
            case .drawing(_, _, let box, _):
                found += [CGPoint(x: box.rect.minX, y: box.rect.minY), CGPoint(x: box.rect.maxX, y: box.rect.maxY)].map { Activity(point: $0, weight: 5) }
            case .pin(_, let point):
                found.append(Activity(point: point, weight: 5))
            case .click(let point, _, _):
                found.append(Activity(point: point, weight: 4))
            case .drag(let start, let end, _, _):
                found += [Activity(point: start, weight: 4), Activity(point: end, weight: 4)]
            case .scroll(let point, _, _):
                found.append(Activity(point: point, weight: 3))
            case .shortcut, .app:
                break
            }
        }
        guard let track = events.cursor else { return found }
        let area = CGRect(x: 0, y: 0, width: events.width, height: events.height)
        for index in track.t.indices {
            let point = CGPoint(x: track.x[index], y: track.y[index])
            guard area.contains(point) else { continue }
            // The pointer counts from when it got here (or from `from`, when it was already resting) until it moved on.
            let start = max(track.t[index], from)
            let end = min(index + 1 < track.t.count ? track.t[index + 1] : track.t[index] + 2, to, start + 2)
            guard end > start else { continue }
            found.append(Activity(point: point, weight: end - start))
        }
        return found
    }

    /// The window holding most of the activity (two when the user worked across two), padded, at least `minWidth`
    /// wide, and grown to show every strong activity. Nil without activity in a window, or when it is most of the area.
    static func crop(_ activity: [Activity], windows: [WindowSnapshot.Window], area: CGRect) -> Crop? {
        var scores = [Double](repeating: 0, count: windows.count)
        var strongIn = [Bool](repeating: false, count: windows.count)
        for item in activity {
            // The frontmost window under the point gets it.
            guard let index = windows.firstIndex(where: { $0.frame.contains(item.point) }) else { continue }
            scores[index] += item.weight
            if item.strong { strongIn[index] = true }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        var chosen = [best]
        if let second = scores.indices.filter({ $0 != best && strongIn[$0] }).max(by: { scores[$0] < scores[$1] }),
           strongIn[best], scores[second] >= scores[best] * 0.3 {
            chosen.append(second)
        }
        var rect = chosen.map { windows[$0].frame }.reduce(CGRect.null) { $0.union($1) }
        for item in activity where item.strong {
            rect = rect.union(CGRect(x: item.point.x - 40, y: item.point.y - 40, width: 80, height: 80))
        }
        rect = rect.insetBy(dx: -padding, dy: -padding).intersection(area)
        if rect.width < minWidth {
            let width = min(minWidth, area.width)
            rect.origin.x = min(max(rect.midX - width / 2, area.minX), area.maxX - width)
            rect.size.width = width
        }
        rect = rect.integral.intersection(area)
        guard !rect.isEmpty, rect.width * rect.height < maxShare * area.width * area.height else { return nil }
        var apps: [String] = []
        for index in chosen where !apps.contains(windows[index].app) { apps.append(windows[index].app) }
        return Crop(rect: rect, apps: apps)
    }

    /// Runs of neighbouring crops that mostly overlap become their union, unless that is most of the area.
    static func merged(_ crops: [Crop?], area: CGRect) -> [Crop?] {
        var result = crops
        var index = 0
        while index < result.count {
            guard var group = result[index] else { index += 1; continue }
            var end = index + 1
            while end < result.count, let next = result[end], overlap(group.rect, next.rect) >= mergeOverlap {
                let union = group.rect.union(next.rect)
                guard union.width * union.height < maxShare * area.width * area.height else { break }
                group.rect = union
                for app in next.apps where !group.apps.contains(app) { group.apps.append(app) }
                end += 1
            }
            for member in index..<end { result[member] = group }
            index = end
        }
        return result
    }

    /// How much two rects overlap, as a share of the smaller one.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let common = a.intersection(b)
        guard !common.isNull, a.width * a.height > 0, b.width * b.height > 0 else { return 0 }
        return common.width * common.height / min(a.width * a.height, b.width * b.height)
    }

    /// "Safari + Notes": every app the crops show, in order.
    static func appNames(_ crops: [Crop?]) -> String {
        var apps: [String] = []
        for crop in crops.compactMap({ $0 }) { for app in crop.apps where !apps.contains(app) { apps.append(app) } }
        return apps.joined(separator: " + ")
    }
}
