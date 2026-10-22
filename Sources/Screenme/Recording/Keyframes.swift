import AVFoundation
import CoreGraphics

/// One frame of a report: the moment it shows, why it was cut, and what was said and done while it was on screen.
struct Keyframe: Equatable {
    typealias Reason = KeyframeReason

    /// Where the frame is taken, in seconds of the video.
    var time: Double
    /// When what it shows began (the click, the start of a screen change). Its speech starts here.
    var moment: Double
    var reason: Reason
    /// What was said from this keyframe's moment until the next keyframe's.
    var text = ""
    /// Indices into the recording's events, for the events from this keyframe's moment until the next one.
    var events: [Int] = []
}

/// A small picture of the video at one time: grayscale, about 64 pixels wide, with its perceptual hash.
struct FrameSample: Equatable {
    var time: Double
    var width: Int
    var height: Int
    var luma: [UInt8]

    /// A 64-bit difference hash: each bit says whether a cell of a 9 × 8 grid is darker than its right neighbour.
    /// Two pictures that look alike have hashes a few bits apart.
    var hash: UInt64 {
        guard width > 0, height > 0 else { return 0 }
        var cells = [Double](repeating: 0, count: 9 * 8)
        for row in 0..<8 {
            for column in 0..<9 {
                let x0 = column * width / 9, x1 = max((column + 1) * width / 9, x0 + 1)
                let y0 = row * height / 8, y1 = max((row + 1) * height / 8, y0 + 1)
                var sum = 0, count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        sum += Int(luma[y * width + x])
                        count += 1
                    }
                }
                cells[row * 9 + column] = count > 0 ? Double(sum) / Double(count) : 0
            }
        }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 where cells[row * 9 + column] < cells[row * 9 + column + 1] {
                hash |= 1 << UInt64(row * 8 + column)
            }
        }
        return hash
    }

    /// The share of pixels that changed by more than a little since `other`, 0 to 1. Pictures of different sizes
    /// are entirely different.
    func difference(from other: FrameSample) -> Double {
        guard width == other.width, height == other.height, !luma.isEmpty else { return 1 }
        var changed = 0
        for index in luma.indices where abs(Int(luma[index]) - Int(other.luma[index])) > 16 { changed += 1 }
        return Double(changed) / Double(luma.count)
    }
}

/// Where a report's keyframes go. Everything here is a pure function of the narration, the events and the
/// sampled pictures, so it is unit tested; `FrameSampler` makes the samples from the video.
enum Keyframes {
    static let maxFrames = 24
    /// Two keyframes are never closer than this, in seconds.
    static let minGap = 0.75
    /// A share of changed pixels that makes a screen change worth a keyframe.
    static let changeThreshold = 0.015
    /// Hashes at least this many bits apart are different pictures.
    static let differentHash = 8

    /// Said deliberately while pointing at something: a keyframe even without a screen change, when the picture is new.
    static let strongCues: Set<String> = ["now", "here", "look", "watch", "qui", "guarda", "ora", "vedi", "ecco"]
    /// Usually filler: a keyframe only when the screen changes around the word.
    static let weakCues: Set<String> = ["this", "that", "these", "those", "questo", "questa", "quello", "quella"]

    /// A stretch of screen changes: when it began, and when the picture had settled.
    struct Change: Equatable {
        var start: Double
        var settled: Double
    }

    /// The screen changes in `samples`: runs of pictures that each differ materially from the one before. A run
    /// ends at the first picture that stays, which is the settled view.
    static func changes(in samples: [FrameSample], threshold: Double = changeThreshold) -> [Change] {
        guard samples.count > 1 else { return [] }
        var changes: [Change] = []
        var open: Double?
        for index in 1..<samples.count {
            let moved = samples[index].difference(from: samples[index - 1]) >= threshold
            if moved {
                if open == nil { open = samples[index - 1].time }
            } else if let start = open {
                changes.append(Change(start: start, settled: samples[index - 1].time))
                open = nil
            }
        }
        if let start = open { changes.append(Change(start: start, settled: samples[samples.count - 1].time)) }
        return changes
    }

    /// The keyframes of a recording, in time order, each with the speech and events it owns.
    ///
    /// A keyframe is cut at the start, when a drawing is finished or a pin dropped, after a click, a drag or a
    /// scroll, after an app or window switch, when the screen settles after a material change, and at a spoken
    /// cue: a strong one ("now", "here", "look", "guarda") at the settled view of a change around the word, or
    /// where it was said; a weak one ("this", "questo") only with such a change. Pauses never cut. Screen changes
    /// and cues add a frame only when its picture differs from every frame already chosen. At most `maxFrames`:
    /// drawings and pins first, then clicks, drags and scrolls, then app switches and the start, then screen changes, then cues.
    static func select(words: [TranscriptSegment], events: RecordingEvents?, samples: [FrameSample], duration: Double,
                       maxFrames: Int = maxFrames) -> [Keyframe] {
        let last = max(duration - 0.1, 0)
        func clamp(_ time: Double) -> Double { min(max(time, 0), last) }
        let changes = changes(in: samples)
        let hashes = samples.map { (time: $0.time, hash: $0.hash) }
        func hash(at time: Double) -> UInt64? {
            hashes.min { abs($0.time - time) < abs($1.time - time) }?.hash
        }

        // (keyframe, priority, gated): a lower priority number is more important; gated ones need a new picture.
        var candidates: [(frame: Keyframe, priority: Int, gated: Bool)] = [
            (Keyframe(time: clamp(0.3), moment: 0, reason: .start), 2, false),
        ]
        let recorded = events?.events ?? []
        for event in recorded {
            switch event.kind {
            case .drawing:
                candidates.append((Keyframe(time: clamp(event.time + 0.2), moment: event.time, reason: .drawing), 0, false))
            case .pin:
                candidates.append((Keyframe(time: clamp(event.time + 0.2), moment: event.time, reason: .pin), 0, false))
            case .click:
                candidates.append((Keyframe(time: clamp(event.time + 0.4), moment: event.time, reason: .click), 1, false))
            case .drag:
                candidates.append((Keyframe(time: clamp((event.until ?? event.time) + 0.3), moment: event.time, reason: .drag), 1, false))
            case .scroll:
                candidates.append((Keyframe(time: clamp((event.until ?? event.time) + 0.3), moment: event.time, reason: .scroll), 1, false))
            case .app:
                candidates.append((Keyframe(time: clamp(event.time + 0.3), moment: event.time, reason: .app), 2, false))
            case .shortcut:
                break
            }
        }
        // A drawing that fades out 3 s after it was finished changes the screen without anything new on it.
        let fades = recorded.filter { $0.kind == .drawing }.map { ($0.time + 2.8)...($0.time + 4) }
        for change in changes where !fades.contains(where: { $0.contains(change.settled) }) {
            candidates.append((Keyframe(time: clamp(change.settled), moment: change.start, reason: .change), 3, true))
        }
        for word in words {
            let cue = cueWord(word.text)
            let strong = strongCues.contains(cue)
            guard strong || weakCues.contains(cue) else { continue }
            if let change = changes.first(where: { $0.start <= word.start + 1.5 && $0.settled >= word.start - 1 }) {
                candidates.append((Keyframe(time: clamp(max(change.settled, word.start)), moment: word.start, reason: .cue), 4, true))
            } else if strong {
                candidates.append((Keyframe(time: clamp(word.start + 0.2), moment: word.start, reason: .cue), 4, true))
            }
        }

        var chosen: [Keyframe] = []
        var chosenHashes: [UInt64] = []
        for candidate in candidates.enumerated().sorted(by: {
            ($0.element.gated ? 1 : 0, $0.element.priority, $0.element.frame.time, $0.offset)
                < ($1.element.gated ? 1 : 0, $1.element.priority, $1.element.frame.time, $1.offset)
        }).map(\.element) where chosen.count < maxFrames {
            if chosen.contains(where: { abs($0.time - candidate.frame.time) < minGap }) { continue }
            let picture = hash(at: candidate.frame.time)
            if candidate.gated {
                guard let picture, chosenHashes.allSatisfy({ ($0 ^ picture).nonzeroBitCount >= differentHash }) else { continue }
            }
            chosen.append(candidate.frame)
            if let picture { chosenHashes.append(picture) }
        }
        chosen.sort { $0.time < $1.time }
        assign(words: words, events: recorded, to: &chosen)
        return chosen
    }

    /// The word without punctuation, in lower case: "Here," is "here".
    static func cueWord(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// Gives each keyframe the words and events from its moment until the next keyframe's. A keyframe's speech
    /// starts at the beginning of the clause in progress at its moment, when that began shortly before; words
    /// before the first keyframe belong to it.
    static func assign(words: [TranscriptSegment], events: [RecordingEvent], to keyframes: inout [Keyframe]) {
        guard !keyframes.isEmpty else { return }
        var boundaries: [Double] = []
        for (index, keyframe) in keyframes.enumerated() {
            let snapped = index == 0 ? -Double.infinity : clauseStart(before: keyframe.moment, in: words)
            boundaries.append(max(snapped, boundaries.last ?? -.infinity))
        }
        func owner(of time: Double) -> Int {
            boundaries.lastIndex { $0 <= time } ?? 0
        }
        var texts = [[String]](repeating: [], count: keyframes.count)
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts[owner(of: word.start)].append(text) }
        }
        for index in keyframes.indices {
            keyframes[index].text = texts[index].joined(separator: " ")
            keyframes[index].events = []
        }
        for (index, event) in events.enumerated() {
            keyframes[owner(of: event.time)].events.append(index)
        }
    }

    /// The start of the clause going on at `time`: the first word after a word ending a clause (`.`, `,`, `?`, `!`,
    /// `;`, `:`) or after a pause of more than 0.6 s, when that is at most 1.5 s earlier. Otherwise `time`.
    static func clauseStart(before time: Double, in words: [TranscriptSegment]) -> Double {
        func endsClause(_ word: TranscriptSegment) -> Bool {
            word.text.trimmingCharacters(in: .whitespaces).last.map { ".,?!;:".contains($0) } ?? false
        }
        guard let current = words.lastIndex(where: { $0.start < time }) else { return time }
        // A clause that was over by the moment, or followed by a pause, is not in progress.
        if words[current].end < time - 0.6 || (endsClause(words[current]) && words[current].end <= time) { return time }
        var start = current
        while start > 0 {
            let previous = words[start - 1]
            if endsClause(previous) || words[start].start - previous.end > 0.6 { break }
            start -= 1
        }
        return time - words[start].start <= 1.5 ? words[start].start : time
    }
}

/// Small grayscale pictures of a video at about two a second, for finding screen changes. The decoder picks
/// the nearest frame it has to each time, so this stays cheap on long recordings.
enum FrameSampler {
    static let width = 64

    static func samples(of asset: AVAsset, duration: Double) async throws -> [FrameSample] {
        guard duration > 0 else { return [] }
        let interval = max(0.5, duration / 1200)
        let times = stride(from: 0.0, through: max(duration - 0.05, 0), by: interval).map { CMTime(seconds: $0, preferredTimescale: 600) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var samples: [FrameSample] = []
        for await result in generator.images(for: times) {
            guard let image = try? result.image, let sample = sample(image, time: result.requestedTime.seconds) else { continue }
            samples.append(sample)
        }
        return samples.sorted { $0.time < $1.time }
    }

    /// The picture in grayscale at its own size (the generator already scaled it down).
    static func sample(_ image: CGImage, time: Double) -> FrameSample? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let luma = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        return FrameSample(time: time, width: width, height: height, luma: luma)
    }
}
