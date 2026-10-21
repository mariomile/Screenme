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

/// A bug report made from a narrated recording: a folder with the video, key frames and `report.md`.
/// Everything here is plain data; `BugReporter` does the transcription, the frames and the files.
struct BugReport {
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

    /// A numbered step: one or more narration segments, and the frame taken where it starts.
    struct Step: Equatable {
        var time: Double
        var text: String
    }

    static let maxFrames = 8
    static let videoName = "recording.mp4"

    /// The report folder.
    var folder: URL
    var environment: Environment
    /// Everything said, in order. Empty when there was no narration.
    var transcript: [TranscriptSegment]
    /// Why there is no transcript ("The recording has no audio."), when it is empty.
    var noNarration: String
    /// The time of each frame, `frames/01.png` first. With narration, one per step.
    var frameTimes: [Double]

    var steps: [Step] { Self.steps(from: transcript) }

    static func frameName(_ index: Int) -> String {
        String(format: "frames/%02d.png", index + 1)
    }

    // MARK: Steps and frames

    /// One step per segment, or, with more than `maxCount` segments, neighbouring segments merged into `maxCount` steps.
    static func steps(from segments: [TranscriptSegment], maxCount: Int = maxFrames) -> [Step] {
        let count = min(segments.count, maxCount)
        return (0..<count).map { group in
            let part = segments[group * segments.count / count..<(group + 1) * segments.count / count]
            return Step(time: part.first!.start, text: part.map(\.text).joined(separator: " "))
        }
    }

    /// Where the frames are taken: at the start of each step, or, without narration, spread evenly over the
    /// recording (about one every two seconds, at most `maxCount`). Always inside the video.
    static func frameTimes(for steps: [Step], duration: Double, maxCount: Int = maxFrames) -> [Double] {
        let last = max(duration - 0.1, 0)
        guard steps.isEmpty else { return steps.prefix(maxCount).map { min(max($0.time, 0), last) } }
        let count = min(max(Int((duration / 2).rounded(.up)), 1), maxCount)
        return (0..<count).map { min((Double($0) + 0.5) * duration / Double(count), last) }
    }

    // MARK: Markdown

    var title: String {
        guard let first = transcript.first?.text else {
            return environment.app.map { "Bug report: \($0)" } ?? "Bug report"
        }
        let words = first.split(separator: " ")
        let short = words.prefix(14).joined(separator: " ")
        return "Bug report: " + (words.count > 14 ? short + "…" : short)
    }

    /// `report.md`. With `absoluteLinks`, images and the video link to their full paths, so the text works on its own
    /// when pasted into a coding agent; otherwise they link inside the folder, for GitHub, Linear or the folder itself.
    func markdown(absoluteLinks: Bool) -> String {
        func link(_ relative: String) -> String {
            absoluteLinks ? "<\(folder.appendingPathComponent(relative).path)>" : relative
        }
        func time(_ seconds: Double) -> String { Duration.format(seconds) }

        var lines = ["# \(title)", "", "## Environment", ""]
        if let app = environment.app { lines.append("- App: \(app)") }
        if let window = environment.window, !window.isEmpty { lines.append("- Window: \(window)") }
        if let page = environment.page { lines.append("- Page: \(page)") }
        lines.append("- macOS: \(environment.system)")
        if let screen = environment.screen { lines.append("- Screen: \(screen)") }
        lines.append("- Recording: \(environment.video)")
        lines.append("- Date: \(environment.date)")

        lines += ["", "## Transcript", ""]
        if transcript.isEmpty {
            lines.append("No narration. \(noNarration)")
        } else {
            lines += transcript.map { "- [\(time($0.start))] \($0.text)" }
        }

        let steps = self.steps
        if steps.isEmpty {
            lines += ["", "## Frames", ""]
            for (index, at) in frameTimes.enumerated() {
                lines.append("![Frame \(index + 1) at \(time(at))](\(link(Self.frameName(index))))")
                lines.append("")
            }
        } else {
            lines += ["", "## Steps", ""]
            for (index, step) in steps.enumerated() {
                lines.append("\(index + 1). [\(time(step.time))] \(step.text)")
                lines.append("")
                lines.append("   ![Step \(index + 1) at \(time(step.time))](\(link(Self.frameName(index))))")
                lines.append("")
            }
        }
        lines += ["## Video", "", "[\(Self.videoName)](\(link(Self.videoName)))", ""]

        lines += ["## For an AI coding agent", ""]
        if steps.isEmpty {
            lines.append("Reproduce and fix the bug shown in this screen recording. It has no narration: work out what goes wrong from the frames, and ask the user what they expected if that is unclear.")
        } else {
            lines.append("Reproduce and fix the bug described above. The user recorded the screen while explaining the problem: the transcript is what they said, and each step has a frame of the screen at that moment.")
        }
        lines.append("Look at every frame before you start (they are PNG files your Read tool can open), find the cause in the code, fix it, and say how you checked the fix.")
        lines.append("")
        for (index, at) in frameTimes.enumerated() {
            lines.append("- Frame \(index + 1) at \(time(at)): `\(folder.appendingPathComponent(Self.frameName(index)).path)`")
        }
        lines.append("- Video: `\(folder.appendingPathComponent(Self.videoName).path)`")
        return lines.joined(separator: "\n") + "\n"
    }
}
