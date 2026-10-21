import Foundation

/// A stretch of narration, in seconds from the start of the recording.
struct TranscriptSegment: Equatable {
    var start: Double
    var end: Double
    var text: String

    /// Sentences from timed words: a segment ends after a word with a full stop, a question or exclamation mark,
    /// or before a pause longer than `pause` seconds. For recognizers that only report words.
    static func sentences(from words: [TranscriptSegment], pause: Double = 1.0) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var open = current, word.start - open.end <= pause {
                open.text += " " + text
                open.end = word.end
                current = open
            } else {
                if let open = current { segments.append(open) }
                current = TranscriptSegment(start: word.start, end: word.end, text: text)
            }
            if let last = text.last, ".?!".contains(last), let open = current {
                segments.append(open)
                current = nil
            }
        }
        if let open = current { segments.append(open) }
        return segments
    }
}

/// A report for an AI agent made from a recording: a folder with the video, key frames, the events and `report.md`,
/// which tells moment by moment what was said, clicked, pressed, switched to and drawn.
/// Everything here is plain data; `AIReporter` does the transcription, the frames and the files.
struct AIReport {
    /// What the recording shows and where it was made.
    struct Environment {
        var app: String?
        var window: String?
        var page: String?
        var system: String
        var screen: String?
        var video: String
        var date: String
    }

    /// One line of the timeline, and the frame that shows it, if it got one.
    struct Moment: Equatable {
        var time: Double
        var text: String
        /// Index into `frameTimes`.
        var frame: Int?
    }

    static let maxFrames = 12
    static let videoName = "recording.mp4"
    static let eventsName = "events.json"

    /// The report folder.
    var folder: URL
    var environment: Environment
    /// Everything said, in order. Empty when there was no narration.
    var transcript: [TranscriptSegment]
    /// Why there is no transcript ("The recording has no audio."), when it is empty.
    var noNarration: String
    /// What happened during the recording. Nil for a recording made without them; `events.json` is written only then.
    var events: RecordingEvents?
    /// The timeline, in time order.
    var moments: [Moment] = []
    /// The time of each frame, `frames/01.png` first.
    var frameTimes: [Double] = []

    static func frameName(_ index: Int) -> String {
        String(format: "frames/%02d.png", index + 1)
    }

    // MARK: Timeline

    /// Fills `moments` and `frameTimes` for a video of `duration` seconds.
    mutating func makeTimeline(duration: Double) {
        (moments, frameTimes) = Self.timeline(transcript: transcript, events: events, duration: duration)
    }

    /// Narration and events merged into one timeline in time order (narration first at the same time), and the frames:
    /// at the start of each narration segment, just after each drawing (so it shows) and each app switch, at most
    /// `maxFrames`. Drawings win over narration, narration over app switches, and two frames are never closer than
    /// 0.75 s. Without any of those, frames are spread evenly over the video and belong to no moment.
    static func timeline(transcript: [TranscriptSegment], events: RecordingEvents?, duration: Double,
                         maxFrames: Int = maxFrames) -> (moments: [Moment], frameTimes: [Double]) {
        // (moment, frame time, priority): a lower priority number is more important.
        var entries: [(moment: Moment, frameAt: Double?, priority: Int)] = transcript.map {
            (Moment(time: $0.start, text: "Said: \"\($0.text)\""), $0.start, 1)
        }
        var lastApp: String?
        for event in events?.events ?? [] {
            let text: String
            var frameAt: Double?
            var priority = 3
            switch event.kind {
            case .click:
                text = clickText(event)
            case .shortcut:
                text = "Pressed \(event.keys ?? "a shortcut")"
            case .app:
                text = appText(event, previous: lastApp)
                lastApp = event.app
                frameAt = event.time + 0.3
                priority = 2
            case .drawing:
                text = drawingText(event, area: CGSize(width: events?.width ?? 0, height: events?.height ?? 0))
                frameAt = event.time + 0.2
                priority = 0
            }
            entries.append((Moment(time: event.time, text: text), frameAt, priority))
        }
        // Stable: at the same time, narration (added first) comes first.
        entries = entries.enumerated().sorted { ($0.element.moment.time, $0.offset) < ($1.element.moment.time, $1.offset) }.map(\.element)

        let last = max(duration - 0.1, 0)
        let candidates = entries.indices.compactMap { index -> (index: Int, time: Double, priority: Int)? in
            entries[index].frameAt.map { (index, min(max($0, 0), last), entries[index].priority) }
        }
        var chosen: [(index: Int, time: Double)] = []
        for candidate in candidates.sorted(by: { ($0.priority, $0.time) < ($1.priority, $1.time) }) where chosen.count < maxFrames {
            if chosen.contains(where: { abs($0.time - candidate.time) < 0.75 }) { continue }
            chosen.append((candidate.index, candidate.time))
        }
        chosen.sort { $0.time < $1.time }

        var moments = entries.map(\.moment)
        for (frame, pick) in chosen.enumerated() { moments[pick.index].frame = frame }
        if chosen.isEmpty { return (moments, evenFrameTimes(duration: duration, maxCount: maxFrames)) }
        return (moments, chosen.map(\.time))
    }

    /// About one frame every two seconds, at most `maxCount`, always inside the video.
    static func evenFrameTimes(duration: Double, maxCount: Int = maxFrames) -> [Double] {
        let last = max(duration - 0.1, 0)
        let count = min(max(Int((duration / 2).rounded(.up)), 1), maxCount)
        return (0..<count).map { min((Double($0) + 0.5) * duration / Double(count), last) }
    }

    private static func clickText(_ event: RecordingEvent) -> String {
        let verb = event.button == "right" ? "Right-clicked" : "Clicked"
        let point = "\(Int(event.x ?? 0)), \(Int(event.y ?? 0))"
        guard let element = event.element else { return "\(verb) at \(point)" }
        return "\(verb) \(element) at \(point)"
    }

    private static func appText(_ event: RecordingEvent, previous: String?) -> String {
        let app = event.app ?? "an app"
        let window = event.window.map { "window \"\($0)\"" }
        guard let previous else { return "In \(app)" + (window.map { ", \($0)" } ?? "") }
        if previous == app, let window { return "Switched to \(window) in \(app)" }
        return "Switched to \(app)" + (window.map { ", \($0)" } ?? "")
    }

    private static func drawingText(_ event: RecordingEvent, area: CGSize) -> String {
        let color = event.color ?? ""
        let box = event.box ?? RecordingEvent.Box(x: 0, y: 0, width: 0, height: 0)
        let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        let place = placeName(of: CGPoint(x: rect.midX, y: rect.midY), in: area)
        let size = "\(Int(box.x)), \(Int(box.y)), \(Int(box.width))×\(Int(box.height))"
        switch LiveDrawTool(rawValue: event.tool ?? "") {
        case .arrow:
            let tip = "\(Int(event.x ?? 0)), \(Int(event.y ?? 0))"
            return "Drew a \(color) arrow \(place), pointing at \(tip)"
        case .rectangle: return "Drew a \(color) rectangle \(place) (\(size))"
        case .highlighter: return "Highlighted in \(color) \(place) (\(size))"
        case .pen, nil: return "Drew in \(color) \(place) (\(size))"
        }
    }

    /// "at the top right", "on the left", "in the middle": where a point is in thirds of the area.
    static func placeName(of point: CGPoint, in area: CGSize) -> String {
        guard area.width > 0, area.height > 0 else { return "on the screen" }
        let column = min(Int(point.x / area.width * 3), 2), row = min(Int(point.y / area.height * 3), 2)
        let vertical = ["top", "", "bottom"][max(row, 0)], horizontal = ["left", "", "right"][max(column, 0)]
        switch (vertical.isEmpty, horizontal.isEmpty) {
        case (true, true): return "in the middle"
        case (true, false): return "on the \(horizontal)"
        case (false, true): return "at the \(vertical)"
        case (false, false): return "at the \(vertical) \(horizontal)"
        }
    }

    // MARK: Markdown

    var title: String {
        guard let first = transcript.first?.text else {
            return environment.app.map { "Report: \($0)" } ?? "Report"
        }
        let words = first.split(separator: " ")
        let short = words.prefix(14).joined(separator: " ")
        return "Report: " + (words.count > 14 ? short + "…" : short)
    }

    /// `report.md`. With `absoluteLinks`, images and the video link to their full paths, so the text works on its own
    /// when pasted into an agent; otherwise they link inside the folder, for GitHub, Linear or the folder itself.
    func markdown(absoluteLinks: Bool) -> String {
        func link(_ relative: String) -> String {
            absoluteLinks ? "<\(folder.appendingPathComponent(relative).path)>" : relative
        }
        func time(_ seconds: Double) -> String { Duration.format(seconds) }
        func path(_ relative: String) -> String { folder.appendingPathComponent(relative).path }

        var lines = ["# \(title)"]
        func heading(_ name: String) {
            while lines.last == "" { lines.removeLast() }
            lines += ["", "## \(name)", ""]
        }

        heading("Environment")
        if let app = environment.app { lines.append("- App: \(app)") }
        if let window = environment.window, !window.isEmpty { lines.append("- Window: \(window)") }
        if let page = environment.page { lines.append("- Page: \(page)") }
        lines.append("- macOS: \(environment.system)")
        if let screen = environment.screen { lines.append("- Screen: \(screen)") }
        lines.append("- Recording: \(environment.video)")
        if let events { lines.append("- Recorded area: \(Int(events.width))×\(Int(events.height)) points") }
        lines.append("- Date: \(environment.date)")

        heading("Timeline")
        if events != nil {
            lines += ["Times are positions in the video. Positions are points from the top-left corner of the recorded area.", ""]
        }
        if moments.isEmpty {
            lines.append("Nothing to show moment by moment: no narration, clicks, shortcuts, app switches or drawings.")
        }
        for moment in moments {
            lines.append("- [\(time(moment.time))] \(moment.text)")
            if let frame = moment.frame {
                lines.append("")
                lines.append("  ![Frame \(frame + 1) at \(time(frameTimes[frame]))](\(link(Self.frameName(frame))))")
                lines.append("")
            }
        }
        if !moments.contains(where: { $0.frame != nil }) {
            heading("Frames")
            for (index, at) in frameTimes.enumerated() {
                lines.append("![Frame \(index + 1) at \(time(at))](\(link(Self.frameName(index))))")
                lines.append("")
            }
        }

        heading("Transcript")
        if transcript.isEmpty {
            lines.append("No narration. \(noNarration)")
        } else {
            lines += transcript.map { "- [\(time($0.start))] \($0.text)" }
        }
        heading("Video")
        lines.append("[\(Self.videoName)](\(link(Self.videoName)))")

        heading("For an AI agent")
        if transcript.isEmpty {
            lines.append("The user recorded the screen without narration to show you something. Work out what they are showing from the frames, clicks, shortcuts and drawings, and ask them what they want if that is unclear.")
        } else {
            lines.append("The user recorded the screen while talking, to show you something and ask for something. What they said is the request; the clicks, shortcuts and app switches are what they did; the drawings mark what they are pointing at.")
        }
        lines.append("Read the timeline in order and look at every frame before you act (they are PNG files your Read tool can open)."
            + (events == nil ? "" : " The events file has the exact time and position of every click, shortcut, app switch and drawing.")
            + " If the request is still unclear, ask the user before you change anything.")
        lines.append("")
        lines.append("- Video: `\(path(Self.videoName))`")
        if events != nil { lines.append("- Events: `\(path(Self.eventsName))`") }
        for (index, at) in frameTimes.enumerated() {
            lines.append("- Frame \(index + 1) at \(time(at)): `\(path(Self.frameName(index)))`")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
