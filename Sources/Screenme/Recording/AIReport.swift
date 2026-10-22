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

    /// The words of each segment, with times spread over it by length. A segment that is already one word stays.
    /// For recognizers that only time whole stretches of speech.
    static func words(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            let parts = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let letters = parts.reduce(0) { $0 + $1.count }
            guard parts.count > 1, letters > 0 else {
                return parts.map { TranscriptSegment(start: segment.start, end: segment.end, text: $0) }
            }
            let perLetter = max(segment.end - segment.start, 0) / Double(letters)
            var start = segment.start
            return parts.map { part in
                let end = start + perLetter * Double(part.count)
                defer { start = end }
                return TranscriptSegment(start: start, end: end, text: part)
            }
        }
    }
}

/// What was said in a recording: sentences or stretches of speech, and every word with its time.
struct Transcript: Equatable {
    var segments: [TranscriptSegment] = []
    var words: [TranscriptSegment] = []
}

/// What was said in a recording, or why there is nothing to read.
enum Narration: Equatable {
    case spoken(Transcript)
    /// Why there is no narration: "The recording has no audio."
    case silent(String)

    /// Everything said, in order. Empty when silent.
    var transcript: Transcript {
        if case .spoken(let transcript) = self { return transcript }
        return Transcript()
    }
}

/// A report for an AI agent made from a recording: a folder with the contact sheet, the keyframes, the video,
/// `summary.md`, which tells keyframe by keyframe what was said, clicked, pressed, switched to and drawn, and
/// `report.json`, the manifest with every word, event, mark and window.
/// Built once from what `AIReporter` gathered, and plain data from then on: `AIReporter` does the transcription,
/// the frames and the files.
struct AIReport {
    typealias Environment = ReportManifest.Environment

    /// An event as the report tells it.
    struct Event: Equatable {
        var recorded: RecordingEvent
        /// "Clicked button "Pay" at 412, 300", "Switched to Safari".
        var text: String
        /// A drawing's number, from 1 in the order they were finished: `screenme zoom --mark N` looks at mark N.
        var mark: Int?
        /// The index of the keyframe it happened under.
        var keyframe: Int
    }

    /// The report folder: where it is built until `AIReporter` moves it into place.
    var folder: URL
    let environment: Environment
    let narration: Narration
    /// The recorded area in points. Nil for a recording made without events.
    let area: CGSize?
    /// The windows over the area through the recording (display and area recordings).
    let windows: [WindowSnapshot]?
    /// The keyframes in time order, `frames/frame-01.png` first, each with what was said and done while it was on
    /// screen and its auto-crop.
    let keyframes: [Keyframe]
    /// What happened, in order. Keyframes point into it.
    let events: [Event]

    init(folder: URL, environment: Environment, narration: Narration, recording: RecordingEvents?, keyframes: [Keyframe]) {
        self.folder = folder
        self.environment = environment
        self.narration = narration
        area = recording.map { CGSize(width: $0.width, height: $0.height) }
        windows = recording?.windows
        self.keyframes = keyframes
        events = Self.describe(recording, keyframes: keyframes)
    }

    var isCropped: Bool { keyframes.contains { $0.crop != nil } }

    // MARK: Events

    /// Each event once, in order: its line, its mark number when it is a drawing, and the keyframe whose events
    /// list it.
    static func describe(_ recording: RecordingEvents?, keyframes: [Keyframe]) -> [Event] {
        guard let recording else { return [] }
        let area = CGSize(width: recording.width, height: recording.height)
        var owners = [Int](repeating: 0, count: recording.events.count)
        for (index, keyframe) in keyframes.enumerated() {
            for event in keyframe.events { owners[event] = index }
        }
        var lastApp: String?
        var marks = 0
        return recording.events.enumerated().map { index, event in
            var described = Event(recorded: event, text: "", mark: nil, keyframe: owners[index])
            switch event.action {
            case .click(let point, let button, let element):
                described.text = (button == .right ? "Right-clicked" : "Clicked") + (element.map { " \($0)" } ?? "") + " at \(coordinates(point))"
            case .drag(let from, let to, _, let element):
                described.text = "Dragged " + (element.map { "\($0) " } ?? "") + "from \(coordinates(from)) to \(coordinates(to))"
            case .scroll(let point, let direction, _):
                described.text = "Scrolled \(direction.rawValue) at \(coordinates(point))"
            case .shortcut(let keys):
                described.text = "Pressed \(keys)"
            case .app(let app, let window):
                described.text = appText(app, window: window, previous: lastApp)
                lastApp = app
            case .drawing(let tool, let color, let box, let tip):
                marks += 1
                described.mark = marks
                described.text = drawingText(tool, color, box: box, tip: tip, area: area) + " (mark \(marks))"
            case .pin(let number, let point):
                described.text = "Dropped pin \(number) \(placeName(of: point, in: area)) (\(coordinates(point)))"
            }
            return described
        }
    }

    /// "412, 300".
    private static func coordinates(_ point: CGPoint) -> String {
        "\(Int(point.x)), \(Int(point.y))"
    }

    private static func appText(_ app: String, window: String?, previous: String?) -> String {
        let window = window.map { "window \"\($0)\"" }
        guard let previous else { return "In \(app)" + (window.map { ", \($0)" } ?? "") }
        if previous == app, let window { return "Switched to \(window) in \(app)" }
        return "Switched to \(app)" + (window.map { ", \($0)" } ?? "")
    }

    private static func drawingText(_ tool: LiveDrawTool, _ color: LiveDrawColor, box: RecordingEvent.Box, tip: CGPoint?,
                                    area: CGSize) -> String {
        let place = placeName(of: CGPoint(x: box.rect.midX, y: box.rect.midY), in: area)
        let size = "\(Int(box.x)), \(Int(box.y)), \(Int(box.width))×\(Int(box.height))"
        switch tool {
        case .arrow: return "Drew a \(color.rawValue) arrow \(place), pointing at \(coordinates(tip ?? CGPoint(x: box.rect.maxX, y: box.rect.midY)))"
        case .rectangle: return "Drew a \(color.rawValue) rectangle \(place) (\(size))"
        case .highlighter: return "Highlighted in \(color.rawValue) \(place) (\(size))"
        case .pen, .pin: return "Drew in \(color.rawValue) \(place) (\(size))"
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

    /// What a keyframe with nothing said shows, by why it was cut.
    static func silentText(_ reason: Keyframe.Reason) -> String {
        switch reason {
        case .start: "(the start)"
        case .change, .scroll: "(the screen changed)"
        case .cue, .drawing, .pin, .click, .drag, .app: "(nothing said)"
        }
    }

    /// The line under a keyframe on the contact sheet: its pins ("pin 3"), then what was said, else what happened,
    /// else why it is there.
    func caption(_ index: Int) -> String {
        let keyframe = keyframes[index]
        let pins = keyframe.events.compactMap { event -> String? in
            guard case .pin(let number, _) = events[event].recorded.action else { return nil }
            return "pin \(number)"
        }
        let prefix = pins.isEmpty ? "" : pins.joined(separator: ", ") + " \u{00B7} "
        if !keyframe.text.isEmpty { return prefix + "\u{201C}\(keyframe.text)\u{201D}" }
        if !pins.isEmpty { return pins.joined(separator: ", ") }
        if let first = keyframe.events.first { return events[first].text }
        return Self.silentText(keyframe.reason)
    }

    /// "Safari + Notes": every app the crops show, in order.
    var croppedApps: String { AutoCrop.appNames(keyframes.map(\.crop)) }

    // MARK: Summary

    var title: String {
        guard case .spoken(let transcript) = narration, let first = transcript.segments.first?.text else {
            return environment.app.map { "Report: \($0)" } ?? "Report"
        }
        let words = first.split(separator: " ")
        let short = words.prefix(14).joined(separator: " ")
        return "Report: " + (words.count > 14 ? short + "…" : short)
    }

    /// `summary.md`, also what is copied: the environment, the keyframes with what was said and done on each,
    /// and what an agent should do, with absolute paths so the text works on its own when pasted.
    var summary: String {
        func time(_ seconds: Double) -> String { Duration.format(seconds) }
        func path(_ relative: String) -> String { folder.appendingPathComponent(relative).path }

        var lines = ["# \(title)", ""]
        func heading(_ name: String) {
            while lines.last == "" { lines.removeLast() }
            lines += ["", "## \(name)", ""]
        }

        if let app = environment.app { lines.append("- App: \(app)") }
        if let window = environment.window, !window.isEmpty { lines.append("- Window: \(window)") }
        if let page = environment.page { lines.append("- Page: \(page)") }
        lines.append("- macOS: \(environment.system)")
        if let screen = environment.screen {
            lines.append("- Screen: \(Int(screen.width))×\(Int(screen.height)) points at \(Int(screen.scale))x")
        }
        let video = environment.video
        lines.append("- Recording: \(video.width)×\(video.height) px, \(time(video.duration))")
        if let area { lines.append("- Recorded area: \(Int(area.width))×\(Int(area.height)) points") }
        lines.append("- Date: \(environment.date.formatted(date: .long, time: .shortened))")
        if isCropped {
            lines += ["", "Cropped to: \(croppedApps) (full frames in frames-full/)"]
        }

        heading("Keyframes")
        lines.append("Each keyframe `#N [time]` has what was said while it was on screen, then what happened, with the time of each event."
            + (area == nil ? "" : " Positions are points from the top-left corner of the recorded area."))
        if case .silent(let why) = narration { lines.append("No narration. \(why)") }
        lines.append("")
        for (index, keyframe) in keyframes.enumerated() {
            let said = keyframe.text.isEmpty ? Self.silentText(keyframe.reason) : "\"\(keyframe.text)\""
            lines.append("- #\(index + 1) [\(time(keyframe.time))] \(said)")
            for event in keyframe.events { lines.append("  - \(time(events[event].recorded.time)) \(events[event].text)") }
        }

        heading("For an AI agent")
        if case .silent = narration {
            lines.append("The user recorded the screen without narration to show you something. Work out what they are showing from the keyframes, clicks, shortcuts and drawings, and ask them what they want if that is unclear.")
        } else {
            lines.append("The user recorded the screen while talking, to show you something and ask for something. What they said is the request; the clicks, shortcuts and app switches are what they did; the drawings mark what they are pointing at.")
        }
        lines.append("Look at the contact sheet first: every keyframe in one picture, numbered #N as above. Then open the frames you need by number: `frames/frame-03.png` is #3 (PNG files your Read tool can open). Red strokes, arrows, boxes and highlights are the user's drawings and point at what matters. "
            + "For a closer look at a moment (something that moves, or happens between keyframes), run `screenme zoom \"\(folder.path)\" --at 0:12` (or `--phrase \"words they said\"`, or `--mark N`): it prints the path of a grid of frames around it. "
            + "If the request is still unclear, ask the user before you change anything.")
        lines.append("")
        lines.append("- Contact sheet: `\(path(ReportLayout.contactSheet))`")
        lines.append("- Frames: `\(path(ReportLayout.frames))`"
            + (keyframes.isEmpty ? "" : " (`\(ReportLayout.frameFile(0))` to `\(ReportLayout.frameFile(keyframes.count - 1))`)"))
        if isCropped {
            lines.append("- Uncropped frames: `\(path(ReportLayout.fullFrames))`, and their contact sheet: `\(path(ReportLayout.fullContactSheet))`")
        }
        lines.append("- Video: `\(path(ReportLayout.video))`")
        lines.append("- Manifest: `\(path(ReportLayout.manifest))` (every word with its time, the events, marks and windows)")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension AIReport {
    var manifest: ReportManifest {
        let entries = keyframes.enumerated().map { index, keyframe in
            ReportManifest.KeyframeEntry(
                number: index + 1, time: keyframe.time, moment: keyframe.moment, reason: keyframe.reason,
                file: ReportLayout.frame(index), fullFile: isCropped ? ReportLayout.fullFrame(index) : nil,
                crop: keyframe.crop.map {
                    ReportManifest.Crop(rect: ReportManifest.Rect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height),
                                        apps: $0.apps)
                },
                text: keyframe.text,
                events: keyframe.events.map {
                    ReportManifest.KeyframeEvent(index: $0, time: events[$0].recorded.time, kind: events[$0].recorded.kind, text: events[$0].text)
                })
        }
        let marks = events.compactMap { event -> ReportManifest.Mark? in
            guard let number = event.mark, case .drawing(let tool, let color, let box, let tip) = event.recorded.action else { return nil }
            return ReportManifest.Mark(number: number, time: event.recorded.time, kind: event.recorded.kind, tool: tool, color: color,
                                       box: box, x: tip.map { Double($0.x) }, y: tip.map { Double($0.y) }, keyframe: event.keyframe + 1)
        }
        func segments(_ list: [TranscriptSegment]) -> [ReportManifest.Segment] {
            list.map { ReportManifest.Segment(start: $0.start, end: $0.end, text: $0.text) }
        }
        let transcript = narration.transcript
        var silence: String?
        if case .silent(let why) = narration { silence = why }
        return ReportManifest(
            title: title, environment: environment,
            area: area.map { ReportManifest.Size(width: $0.width, height: $0.height) },
            video: ReportLayout.video, summary: ReportLayout.summary, contactSheet: ReportLayout.contactSheet,
            contactSheetFull: isCropped ? ReportLayout.fullContactSheet : nil,
            croppedTo: isCropped ? croppedApps : nil,
            keyframes: entries,
            transcript: ReportManifest.Transcript(segments: segments(transcript.segments), words: segments(transcript.words),
                                                  noNarration: silence),
            marks: marks, events: events.map(\.recorded), windows: windows)
    }
}
