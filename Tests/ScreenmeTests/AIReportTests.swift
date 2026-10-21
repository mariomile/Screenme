import AppKit
import AVFoundation
import XCTest
@testable import Screenme

/// Report for AI: narration and events into one timeline, where the frames go, report.md, the events sidecar,
/// and the folder made from a real (silent) video.
@MainActor
final class AIReportTests: XCTestCase {
    private func segment(_ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text)
    }

    private func report(transcript: [TranscriptSegment], events: RecordingEvents?, duration: Double = 10) -> AIReport {
        let environment = AIReport.Environment(app: "Safari", window: "Checkout", page: "https://shop.example/checkout",
                                               system: "27.0.1", screen: "1512×982 points at 2x",
                                               video: "3024×1964 px, 0:12", date: "21 October 2026 at 10:22")
        var report = AIReport(folder: URL(fileURLWithPath: "/Users/me/Desktop/Report 1", isDirectory: true),
                              environment: environment, transcript: transcript,
                              noNarration: "The recording has no audio.", events: events)
        report.makeTimeline(duration: duration)
        return report
    }

    /// An app, a click on a named button, a shortcut, an arrow and a window switch, in a 1000 × 600 point area.
    private let sampleEvents = RecordingEvents(width: 1000, height: 600, events: [
        .app("Safari", window: "Checkout", time: 0),
        RecordingEvent(time: 2, kind: .click, x: 412, y: 300, element: "button \"Pay\""),
        .shortcut("⌘R", time: 3),
        .drawing(.arrow, color: .red, box: CGRect(x: 600, y: 40, width: 200, height: 100), tip: CGPoint(x: 790, y: 50), time: 4),
        .app("Safari", window: "Receipt", time: 8),
    ])

    // MARK: Narration

    func testWordsBecomeSentencesAtPunctuationAndPauses() {
        let words = [("I", 0.0), ("click", 0.3), ("save.", 0.6), ("Nothing", 1.2), ("happens", 1.5),
                     ("then", 4.0), ("it", 4.3), ("crashes", 4.6)]
            .map { TranscriptSegment(start: $0.1, end: $0.1 + 0.25, text: $0.0) }
        XCTAssertEqual(TranscriptSegment.sentences(from: words), [
            TranscriptSegment(start: 0, end: 0.85, text: "I click save."),
            TranscriptSegment(start: 1.2, end: 1.75, text: "Nothing happens"),
            TranscriptSegment(start: 4.0, end: 4.85, text: "then it crashes"),
        ])
    }

    // MARK: Timeline

    func testNarrationAndEventsMergeInTimeOrder() {
        let timeline = AIReport.timeline(transcript: [segment(1, "Look at this total."), segment(6, "It should be 42.")],
                                         events: sampleEvents, duration: 10)
        XCTAssertEqual(timeline.moments.map(\.time), [0, 1, 2, 3, 4, 6, 8])
        XCTAssertEqual(timeline.moments.map(\.text), [
            "In Safari, window \"Checkout\"",
            "Said: \"Look at this total.\"",
            "Clicked button \"Pay\" at 412, 300",
            "Pressed ⌘R",
            "Drew a red arrow at the top right, pointing at 790, 50",
            "Said: \"It should be 42.\"",
            "Switched to window \"Receipt\" in Safari",
        ])
    }

    func testNarrationComesFirstAtTheSameTime() {
        let events = RecordingEvents(width: 100, height: 100, events: [.shortcut("⌘S", time: 2)])
        let moments = AIReport.timeline(transcript: [segment(2, "Saving now.")], events: events, duration: 5).moments
        XCTAssertEqual(moments.map(\.text), ["Said: \"Saving now.\"", "Pressed ⌘S"])
    }

    func testClicksWithoutAccessibilityAndAppSwitchesReadWell() {
        let events = RecordingEvents(width: 100, height: 100, events: [
            .app("Notes", window: nil, time: 0),
            .click(at: CGPoint(x: 10.4, y: 20.6), right: true, time: 1),
            .app("Safari", window: "Docs", time: 2),
        ])
        XCTAssertEqual(AIReport.timeline(transcript: [], events: events, duration: 5).moments.map(\.text),
                       ["In Notes", "Right-clicked at 10, 21", "Switched to Safari, window \"Docs\""])
    }

    func testDrawingsSayWhatAndWhere() {
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)
        let events = RecordingEvents(width: area.width, height: area.height, events: [
            .drawing(.rectangle, color: .blue, box: CGRect(x: 10, y: 400, width: 100, height: 50), tip: nil, time: 1),
            .drawing(.highlighter, color: .yellow, box: CGRect(x: 400, y: 250, width: 100, height: 20), tip: nil, time: 2),
            .drawing(.pen, color: .green, box: CGRect(x: 800, y: 280, width: 50, height: 40), tip: nil, time: 3),
        ])
        XCTAssertEqual(AIReport.timeline(transcript: [], events: events, duration: 5).moments.map(\.text), [
            "Drew a blue rectangle at the bottom left (10, 400, 100×50)",
            "Highlighted in yellow in the middle (400, 250, 100×20)",
            "Drew in green on the right (800, 280, 50×40)",
        ])
    }

    func testPlaceNames() {
        let area = CGSize(width: 300, height: 300)
        XCTAssertEqual(AIReport.placeName(of: CGPoint(x: 10, y: 10), in: area), "at the top left")
        XCTAssertEqual(AIReport.placeName(of: CGPoint(x: 150, y: 10), in: area), "at the top")
        XCTAssertEqual(AIReport.placeName(of: CGPoint(x: 150, y: 150), in: area), "in the middle")
        XCTAssertEqual(AIReport.placeName(of: CGPoint(x: 299, y: 150), in: area), "on the right")
        XCTAssertEqual(AIReport.placeName(of: CGPoint(x: 300, y: 300), in: area), "at the bottom right")
        XCTAssertEqual(AIReport.placeName(of: .zero, in: .zero), "on the screen")
    }

    // MARK: Frames

    func testFramesAtNarrationDrawingsAndAppSwitches() {
        let timeline = AIReport.timeline(transcript: [segment(1, "Look at this total."), segment(6, "It should be 42.")],
                                         events: sampleEvents, duration: 10)
        // The first app's frame (0.3 s) is too close to the narration at 1 s; the arrow's comes just after it is drawn.
        XCTAssertEqual(timeline.frameTimes.map { ($0 * 10).rounded() / 10 }, [1, 4.2, 6, 8.3])
        XCTAssertEqual(timeline.moments.map(\.frame), [nil, 0, nil, nil, 1, 2, 3])
    }

    func testADrawingWinsOverNarrationAtTheSameMoment() {
        let events = RecordingEvents(width: 100, height: 100, events: [
            .drawing(.pen, color: .red, box: CGRect(x: 0, y: 0, width: 20, height: 20), tip: nil, time: 3),
        ])
        let timeline = AIReport.timeline(transcript: [segment(3, "Here.")], events: events, duration: 10)
        XCTAssertEqual(timeline.frameTimes.count, 1)
        XCTAssertEqual(timeline.frameTimes[0], 3.2, accuracy: 0.001)
        XCTAssertEqual(timeline.moments.map(\.frame), [nil, 0])
    }

    func testFramesAreCappedSpacedAndInsideTheVideo() {
        let transcript = (0..<30).map { segment(Double($0), "s\($0)") }
        let events = RecordingEvents(width: 100, height: 100, events: [
            .drawing(.pen, color: .red, box: CGRect(x: 0, y: 0, width: 20, height: 20), tip: nil, time: 29.95),
        ])
        let timeline = AIReport.timeline(transcript: transcript, events: events, duration: 30)
        XCTAssertEqual(timeline.frameTimes.count, AIReport.maxFrames)
        XCTAssertEqual(timeline.frameTimes, timeline.frameTimes.sorted())
        XCTAssertEqual(timeline.frameTimes.last, 29.9, "the drawing's frame is kept and moved inside the video")
        XCTAssertEqual(timeline.moments.compactMap(\.frame), Array(0..<AIReport.maxFrames))
    }

    func testWithNothingToShowFramesAreSpreadEvenly() {
        let timeline = AIReport.timeline(transcript: [], events: nil, duration: 4)
        XCTAssertTrue(timeline.moments.isEmpty)
        XCTAssertEqual(timeline.frameTimes, [1, 3])
        XCTAssertEqual(AIReport.evenFrameTimes(duration: 0.5), [0.25])
        let long = AIReport.evenFrameTimes(duration: 120)
        XCTAssertEqual(long.count, AIReport.maxFrames)
        XCTAssertEqual(long.first, 5)
    }

    // MARK: report.md

    func testReportWithNarrationAndEvents() {
        let report = report(transcript: [segment(1, "Look at this total."), segment(6, "It should be 42.")], events: sampleEvents)
        XCTAssertEqual(report.markdown(absoluteLinks: false), """
        # Report: Look at this total.

        ## Environment

        - App: Safari
        - Window: Checkout
        - Page: https://shop.example/checkout
        - macOS: 27.0.1
        - Screen: 1512×982 points at 2x
        - Recording: 3024×1964 px, 0:12
        - Recorded area: 1000×600 points
        - Date: 21 October 2026 at 10:22

        ## Timeline

        Times are positions in the video. Positions are points from the top-left corner of the recorded area.

        - [0:00] In Safari, window "Checkout"
        - [0:01] Said: "Look at this total."

          ![Frame 1 at 0:01](frames/01.png)

        - [0:02] Clicked button "Pay" at 412, 300
        - [0:03] Pressed ⌘R
        - [0:04] Drew a red arrow at the top right, pointing at 790, 50

          ![Frame 2 at 0:04](frames/02.png)

        - [0:06] Said: "It should be 42."

          ![Frame 3 at 0:06](frames/03.png)

        - [0:08] Switched to window "Receipt" in Safari

          ![Frame 4 at 0:08](frames/04.png)

        ## Transcript

        - [0:01] Look at this total.
        - [0:06] It should be 42.

        ## Video

        [recording.mp4](recording.mp4)

        ## For an AI agent

        The user recorded the screen while talking, to show you something and ask for something. What they said is the request; the clicks, shortcuts and app switches are what they did; the drawings mark what they are pointing at.
        Read the timeline in order and look at every frame before you act (they are PNG files your Read tool can open). The events file has the exact time and position of every click, shortcut, app switch and drawing. If the request is still unclear, ask the user before you change anything.

        - Video: `/Users/me/Desktop/Report 1/recording.mp4`
        - Events: `/Users/me/Desktop/Report 1/events.json`
        - Frame 1 at 0:01: `/Users/me/Desktop/Report 1/frames/01.png`
        - Frame 2 at 0:04: `/Users/me/Desktop/Report 1/frames/02.png`
        - Frame 3 at 0:06: `/Users/me/Desktop/Report 1/frames/03.png`
        - Frame 4 at 0:08: `/Users/me/Desktop/Report 1/frames/04.png`

        """)
    }

    func testClipboardVersionLinksAbsolutePaths() {
        let markdown = report(transcript: [segment(2, "It breaks.")], events: nil).markdown(absoluteLinks: true)
        XCTAssertTrue(markdown.contains("![Frame 1 at 0:02](</Users/me/Desktop/Report 1/frames/01.png>)"))
        XCTAssertTrue(markdown.contains("[recording.mp4](</Users/me/Desktop/Report 1/recording.mp4>)"))
        XCTAssertFalse(markdown.contains("](frames/"))
    }

    func testReportWithoutEventsOrNarrationShowsFramesAndSaysWhy() {
        let markdown = report(transcript: [], events: nil, duration: 4).markdown(absoluteLinks: false)
        XCTAssertTrue(markdown.hasPrefix("# Report: Safari\n"))
        XCTAssertTrue(markdown.contains("## Timeline\n\nNothing to show moment by moment"))
        XCTAssertTrue(markdown.contains("## Frames\n\n![Frame 1 at 0:01](frames/01.png)\n\n![Frame 2 at 0:03](frames/02.png)\n\n## Transcript"))
        XCTAssertTrue(markdown.contains("## Transcript\n\nNo narration. The recording has no audio.\n"))
        XCTAssertTrue(markdown.contains("without narration"))
        XCTAssertFalse(markdown.contains("events.json"))
        XCTAssertFalse(markdown.contains("Recorded area"))
    }

    func testLongFirstSentenceIsShortenedForTheTitle() {
        let long = "When I drag the second card onto the first column the whole board scrolls back to the top and loses it"
        XCTAssertEqual(report(transcript: [segment(0, long)], events: nil).title,
                       "Report: When I drag the second card onto the first column the whole board scrolls…")
    }

    // MARK: Events

    func testOnlyShortcutsAreRecordedNeverTyping() {
        func keys(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String? = nil) -> String? {
            RecordingEvents.shortcut(keyCode: code, flags: flags, characters: characters)
        }
        XCTAssertNil(keys(0, [], "a"), "plain typing")
        XCTAssertNil(keys(0, .shift, "a"), "a capital letter")
        XCTAssertNil(keys(18, [], "1"))
        XCTAssertNil(keys(49, [], " "), "Space types a space")
        XCTAssertNil(keys(51), "Delete edits text")
        XCTAssertEqual(keys(1, .command, "s"), "⌘S")
        XCTAssertEqual(keys(2, [.command, .option], "d"), "⌥⌘D")
        XCTAssertEqual(keys(0, .control, "a"), "⌃A")
        XCTAssertEqual(keys(36), "Return")
        XCTAssertEqual(keys(53), "Esc")
        XCTAssertEqual(keys(48, .shift), "⇧Tab")
        XCTAssertEqual(keys(123), "←")
        XCTAssertEqual(keys(126), "↑")
    }

    func testElementNames() {
        XCTAssertEqual(RecordingEventRecorder.describe(role: "button", name: "Save"), "button \"Save\"")
        XCTAssertEqual(RecordingEventRecorder.describe(role: "AXButton", name: " "), "button")
        XCTAssertEqual(RecordingEventRecorder.describe(role: nil, name: "Line\nbreak"), "\"Line break\"")
        XCTAssertNil(RecordingEventRecorder.describe(role: nil, name: nil))
        let long = RecordingEventRecorder.describe(role: "text", name: String(repeating: "x", count: 100))
        XCTAssertEqual(long, "text \"" + String(repeating: "x", count: 80) + "…\"")
    }

    func testSidecarIsHiddenNextToTheVideoAndReadBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("Screenme 2026-10-21 at 10.22.33.mp4")
        let sidecar = RecordingEvents.sidecarURL(for: video)
        XCTAssertEqual(sidecar.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(sidecar.lastPathComponent, ".Screenme 2026-10-21 at 10.22.33.mp4.events.json")

        RecordingEvents.record(sampleEvents, for: video)
        XCTAssertEqual(try JSONDecoder().decode(RecordingEvents.self, from: Data(contentsOf: sidecar)), sampleEvents)
        let listed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        XCTAssertTrue(listed.isEmpty, "a listing that skips hidden files never sees the sidecar")

        // A recording from an earlier launch: only the sidecar knows its events.
        let older = directory.appendingPathComponent("older.mp4")
        try sampleEvents.json().write(to: RecordingEvents.sidecarURL(for: older))
        XCTAssertEqual(RecordingEvents.events(for: older), sampleEvents)
        XCTAssertNil(RecordingEvents.events(for: directory.appendingPathComponent("none.mp4")))

        RecordingEvents.forget(video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: Folder

    func testWritesFolderFromASilentRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 3)
        let events = RecordingEvents(width: 320, height: 240, events: [
            .drawing(.rectangle, color: .red, box: CGRect(x: 10, y: 10, width: 100, height: 50), tip: nil, time: 1),
        ])

        let report = try await AIReporter.write(video, context: CaptureContext(app: "Notes", window: "Ideas"), events: events,
                                                recordedAt: Date(), in: directory)

        XCTAssertEqual(report.folder.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(report.folder.lastPathComponent.hasPrefix("Report "))
        XCTAssertEqual(report.frameTimes.count, 1)
        XCTAssertEqual(report.frameTimes[0], 1.2, accuracy: 0.001)
        let files = FileManager.default
        XCTAssertTrue(files.fileExists(atPath: report.folder.appendingPathComponent("recording.mp4").path))
        let image = try XCTUnwrap(NSImage(contentsOf: report.folder.appendingPathComponent("frames/01.png")))
        XCTAssertEqual(image.size, CGSize(width: 320, height: 240))
        let written = try JSONDecoder().decode(RecordingEvents.self, from: Data(contentsOf: report.folder.appendingPathComponent("events.json")))
        XCTAssertEqual(written, events)
        let markdown = try String(contentsOf: report.folder.appendingPathComponent("report.md"), encoding: .utf8)
        XCTAssertEqual(markdown, report.markdown(absoluteLinks: false))
        XCTAssertTrue(markdown.contains("No narration. The recording has no audio."))
        XCTAssertTrue(markdown.contains("- App: Notes\n- Window: Ideas\n"))
        XCTAssertTrue(markdown.contains("- Recording: 320×240 px, 0:03"))
        XCTAssertTrue(markdown.contains("- [0:01] Drew a red rectangle at the top left (10, 10, 100×50)\n\n  ![Frame 1 at 0:01](frames/01.png)"))

        // A second report from the same second gets its own folder; without events there is no events.json.
        let again = try await AIReporter.write(video, context: CaptureContext(), events: nil, recordedAt: Date(), in: directory)
        XCTAssertNotEqual(again.folder, report.folder)
        XCTAssertFalse(files.fileExists(atPath: again.folder.appendingPathComponent("events.json").path))
        XCTAssertEqual(again.frameTimes, [0.75, 2.25])
    }

    /// A gray H.264 video with no audio track, 10 frames a second.
    private static func writeSilentVideo(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 8), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
