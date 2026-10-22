import AppKit
import AVFoundation
import XCTest
@testable import Screenme

/// Report for AI: the words of the narration, where the keyframes go and what each one owns, summary.md, report.json,
/// the events sidecar, and the folder made from a real (silent) video.
@MainActor
final class AIReportTests: XCTestCase {
    private func segment(_ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text)
    }

    /// Timed words, each 0.25 s long.
    private func words(_ list: [(String, Double)]) -> [TranscriptSegment] {
        list.map { TranscriptSegment(start: $0.1, end: $0.1 + 0.25, text: $0.0) }
    }

    /// A 9 × 8 picture: 0 brightens to the right, 1 darkens to the right, 2 has stripes.
    private func picture(_ time: Double, _ kind: Int) -> FrameSample {
        FrameSample(time: time, width: 9, height: 8, luma: (0..<72).map { pixel(kind, $0) })
    }

    private func pixel(_ kind: Int, _ index: Int) -> UInt8 {
        let column = index % 9
        switch kind {
        case 0: return UInt8(column * 20)
        case 1: return UInt8((8 - column) * 20)
        default: return column % 2 == 0 ? 0 : 200
        }
    }

    private let recordedAt = ISO8601DateFormatter().date(from: "2026-10-21T08:22:00Z")!

    /// A report without pictures: keyframes from the narration and the events, and `crops` by keyframe index.
    private func report(transcript: [TranscriptSegment], events: RecordingEvents?, duration: Double = 10,
                        crops: [Int: AutoCrop.Crop] = [:]) -> AIReport {
        let environment = AIReport.Environment(app: "Safari", window: "Checkout", page: "https://shop.example/checkout",
                                               system: "27.0.1", screen: AIReport.Environment.Screen(width: 1512, height: 982, scale: 2),
                                               video: AIReport.Environment.Video(width: 3024, height: 1964, duration: duration),
                                               date: recordedAt)
        let narration: Narration = transcript.isEmpty ? .silent("The recording has no audio.")
            : .spoken(Transcript(segments: transcript, words: TranscriptSegment.words(in: transcript)))
        var keyframes = Keyframes.select(words: narration.transcript.words, events: events, samples: [], duration: duration)
        for (index, crop) in crops { keyframes[index].crop = crop }
        return AIReport(folder: URL(fileURLWithPath: "/Users/me/Desktop/Report 1", isDirectory: true), environment: environment,
                        narration: narration, recording: events, keyframes: keyframes)
    }

    /// An app, a click on a named button, a shortcut, an arrow and a window switch, in a 1000 × 600 point area.
    private let sampleEvents = RecordingEvents(width: 1000, height: 600, events: [
        .app("Safari", window: "Checkout", time: 0),
        .click(at: CGPoint(x: 412, y: 300), element: "button \"Pay\"", time: 2),
        .shortcut("⌘R", time: 3),
        .drawing(.arrow, color: .red, box: CGRect(x: 600, y: 40, width: 200, height: 100), tip: CGPoint(x: 790, y: 50), time: 4),
        .app("Safari", window: "Receipt", time: 8),
    ])

    // MARK: Narration

    func testWordsBecomeSentencesAtPunctuationAndPauses() {
        let words = words([("I", 0.0), ("click", 0.3), ("save.", 0.6), ("Nothing", 1.2), ("happens", 1.5),
                           ("then", 4.0), ("it", 4.3), ("crashes", 4.6)])
        XCTAssertEqual(TranscriptSegment.sentences(from: words), [
            TranscriptSegment(start: 0, end: 0.85, text: "I click save."),
            TranscriptSegment(start: 1.2, end: 1.75, text: "Nothing happens"),
            TranscriptSegment(start: 4.0, end: 4.85, text: "then it crashes"),
        ])
    }

    func testSegmentsAreSpreadIntoWordsByLength() {
        let words = TranscriptSegment.words(in: [TranscriptSegment(start: 2, end: 4, text: "ab  cdef ab"), segment(9, "one")])
        XCTAssertEqual(words.map(\.text), ["ab", "cdef", "ab", "one"])
        XCTAssertEqual(words.map(\.start), [2, 2.5, 3.5, 9])
        XCTAssertEqual(words.map(\.end), [2.5, 3.5, 4, 10])
    }

    // MARK: Screen changes

    func testPicturesHaveHashesAndDifferences() {
        XCTAssertEqual(picture(0, 0).hash, UInt64.max, "every cell is darker than its right neighbour")
        XCTAssertEqual(picture(0, 1).hash, 0)
        XCTAssertEqual(picture(0, 2).hash.nonzeroBitCount, 32)
        XCTAssertEqual(picture(0, 0).difference(from: picture(1, 0)), 0)
        XCTAssertEqual(picture(0, 0).difference(from: picture(1, 1)), 64.0 / 72, accuracy: 0.001, "only the middle column is the same")
        XCTAssertEqual(picture(0, 0).difference(from: FrameSample(time: 0, width: 4, height: 4, luma: [UInt8](repeating: 0, count: 16))), 1)
    }

    func testChangesEndAtTheSettledView() {
        let samples = [0, 0, 1, 1, 1, 2, 0].enumerated().map { picture(Double($0.offset) * 0.5, $0.element) }
        XCTAssertEqual(Keyframes.changes(in: samples), [
            Keyframes.Change(start: 0.5, settled: 1.0),
            Keyframes.Change(start: 2.0, settled: 3.0),
        ], "the second change runs to the end: its last picture is its settled view")
        XCTAssertEqual(Keyframes.changes(in: [picture(0, 0)]), [])
    }

    // MARK: Keyframes

    func testKeyframesAtTheStartDrawingsClicksAndAppSwitches() {
        let keyframes = Keyframes.select(words: [], events: sampleEvents, samples: [], duration: 10)
        // The first app switch (0.3 s) is the start's frame; shortcuts never cut.
        XCTAssertEqual(keyframes.map(\.reason), [.start, .click, .drawing, .app])
        XCTAssertEqual(keyframes.map(\.time), [0.3, 2.4, 4.2, 8.3])
        XCTAssertEqual(keyframes.map(\.moment), [0, 2, 4, 8])
        XCTAssertEqual(keyframes.map(\.events), [[0], [1, 2], [3], [4]])
    }

    func testDragsAndScrollsCutWhenTheyEnd() {
        let events = RecordingEvents(width: 100, height: 100, events: [
            RecordingEvent(time: 2, action: .drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 10), until: 3, element: nil)),
            RecordingEvent(time: 5, action: .scroll(at: CGPoint(x: 50, y: 50), .down, until: 6.5)),
        ])
        let keyframes = Keyframes.select(words: [], events: events, samples: [], duration: 10)
        XCTAssertEqual(keyframes.map(\.reason), [.start, .drag, .scroll])
        XCTAssertEqual(keyframes.map(\.time), [0.3, 3.3, 6.8])
        XCTAssertEqual(AIReport.describe(events, keyframes: keyframes).map(\.text), ["Dragged from 10, 10 to 80, 10", "Scrolled down at 50, 50"])
        XCTAssertEqual(AIReport.describe(events, keyframes: keyframes).map(\.keyframe), [1, 2])
    }

    func testAScreenChangeCutsAtItsSettledViewOnlyWhenThePictureIsNew() {
        // Kinds 0, 1, 2, then back to 1: the last change shows a picture that already has a keyframe.
        let kinds = [0, 0, 0, 1, 1, 1, 2, 2, 2, 1, 1]
        let samples = kinds.enumerated().map { picture(Double($0.offset) * 0.5, $0.element) }
        let keyframes = Keyframes.select(words: [], events: nil, samples: samples, duration: 5.5)
        XCTAssertEqual(keyframes.map(\.reason), [.start, .change, .change])
        XCTAssertEqual(keyframes.map(\.time), [0.3, 1.5, 3.0])
        XCTAssertEqual(keyframes.map(\.moment), [0, 1.0, 2.5])
    }

    func testAFadingDrawingIsNotAScreenChange() {
        let events = RecordingEvents(width: 100, height: 100, events: [
            .drawing(.pen, color: .red, box: CGRect(x: 0, y: 0, width: 20, height: 20), tip: nil, time: 1),
        ])
        // The ink appears at 1 s and fades at 4 s.
        let samples = [0, 0, 0, 2, 2, 2, 2, 2, 2, 1, 1, 1].enumerated().map { picture(Double($0.offset) * 0.5, $0.element) }
        let keyframes = Keyframes.select(words: [], events: events, samples: samples, duration: 6)
        XCTAssertEqual(keyframes.map(\.reason), [.start, .drawing])
    }

    func testSpokenCuesCutOnlyANewPictureAndPausesNeverCut() {
        // The screen turns from picture 0 into picture 1 one pixel every half second: never a material change.
        var luma = (0..<72).map { pixel(0, $0) }
        var samples = [FrameSample(time: 0, width: 9, height: 8, luma: luma)]
        for index in 0..<72 {
            luma[index] = pixel(1, index)
            samples.append(FrameSample(time: Double(index + 1) * 0.5, width: 9, height: 8, luma: luma))
        }
        XCTAssertEqual(Keyframes.changes(in: samples), [])
        let said = words([("Look", 2), ("here.", 2.3), ("Long", 10), ("pause", 10.3), ("then", 20), ("this", 37), ("now", 37.5)])
        let keyframes = Keyframes.select(words: said, events: nil, samples: samples, duration: 37)
        // "Look here" shows the same picture as the start; "this" is filler without a change; "now" is new.
        XCTAssertEqual(keyframes.map(\.reason), [.start, .cue])
        XCTAssertEqual(keyframes[1].time, 36.9, accuracy: 0.001, "kept inside the video")
        XCTAssertEqual(keyframes[1].text, "this now", "from the start of the clause in progress")
        XCTAssertEqual(keyframes[0].text, "Look here. Long pause then")
        XCTAssertEqual(Keyframes.select(words: said, events: nil, samples: [], duration: 37).count, 1, "no pictures, no cues")
    }

    func testEachKeyframeOwnsTheSpeechFromTheClauseInProgressUntilTheNext() {
        let events = RecordingEvents(width: 100, height: 100, events: [.click(at: CGPoint(x: 5, y: 5), time: 2)])
        let said = words([("Open", 0.5), ("the", 0.8), ("menu.", 1.0), ("Then", 1.8), ("click", 2.1), ("save.", 2.4),
                          ("It", 4.0), ("fails.", 4.3)])
        let keyframes = Keyframes.select(words: said, events: events, samples: [], duration: 6)
        XCTAssertEqual(keyframes.map(\.text), ["Open the menu.", "Then click save. It fails."])
        XCTAssertEqual(keyframes.map(\.events), [[], [0]])
        XCTAssertEqual(Keyframes.clauseStart(before: 2, in: said), 1.8)
        XCTAssertEqual(Keyframes.clauseStart(before: 3.5, in: said), 3.5, "nothing was being said")
    }

    func testPinsGetAKeyframeAndShowOnTheSheetAndInTheSummary() {
        let events = RecordingEvents(width: 900, height: 600, events: [
            .click(at: CGPoint(x: 10, y: 10), time: 2),
            .pin(1, at: CGPoint(x: 100, y: 80), time: 2.3),
            .pin(2, at: CGPoint(x: 850, y: 550), time: 6),
        ])
        let report = report(transcript: [segment(6, "This one is wrong.")], events: events)
        XCTAssertEqual(report.keyframes.map(\.reason), [.start, .pin, .pin], "a pin wins over a click next to it")
        XCTAssertEqual(report.keyframes.map(\.time), [0.3, 2.5, 6.2])
        XCTAssertEqual(report.caption(1), "pin 1")
        XCTAssertEqual(report.caption(2), "pin 2 \u{00B7} \u{201C}This one is wrong.\u{201D}")
        XCTAssertTrue(report.summary.contains("- #3 [0:06] \"This one is wrong.\"\n  - 0:06 Dropped pin 2 at the bottom right (850, 550)\n"))
        XCTAssertEqual(AutoCrop.activity(from: 5, to: 7, in: events), [AutoCrop.Activity(point: CGPoint(x: 850, y: 550), weight: 5)])
        XCTAssertTrue(report.manifest.marks.isEmpty, "pins are not marks: they have their own numbers")
    }

    func testKeyframesAreCappedByPriorityAndInsideTheVideo() {
        var list = (0..<30).map { RecordingEvent.click(at: .zero, time: Double($0)) }
        list.append(.drawing(.pen, color: .red, box: CGRect(x: 0, y: 0, width: 20, height: 20), tip: nil, time: 29.95))
        let keyframes = Keyframes.select(words: [], events: RecordingEvents(width: 100, height: 100, events: list), samples: [], duration: 30)
        XCTAssertEqual(keyframes.count, Keyframes.maxFrames)
        XCTAssertEqual(keyframes.map(\.time), keyframes.map(\.time).sorted())
        XCTAssertEqual(keyframes.last?.reason, .drawing)
        XCTAssertEqual(keyframes.last?.time, 29.9, "the drawing's frame is kept and moved inside the video")
        XCTAssertFalse(keyframes.contains { $0.reason == .start }, "clicks win over the start")
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

    func testEventsReadWell() {
        let events = RecordingEvents(width: 900, height: 600, events: [
            .app("Notes", window: nil, time: 0),
            .click(at: CGPoint(x: 10.4, y: 20.6), button: .right, time: 1),
            .app("Safari", window: "Docs", time: 2),
            .app("Safari", window: "Docs 2", time: 3),
            .drawing(.rectangle, color: .blue, box: CGRect(x: 10, y: 400, width: 100, height: 50), tip: nil, time: 4),
            .drawing(.highlighter, color: .yellow, box: CGRect(x: 400, y: 250, width: 100, height: 20), tip: nil, time: 5),
            .drawing(.pen, color: .green, box: CGRect(x: 800, y: 280, width: 50, height: 40), tip: nil, time: 6),
        ])
        XCTAssertEqual(AIReport.describe(events, keyframes: []).map(\.text), [
            "In Notes", "Right-clicked at 10, 21", "Switched to Safari, window \"Docs\"", "Switched to window \"Docs 2\" in Safari",
            "Drew a blue rectangle at the bottom left (10, 400, 100×50) (mark 1)",
            "Highlighted in yellow in the middle (400, 250, 100×20) (mark 2)",
            "Drew in green on the right (800, 280, 50×40) (mark 3)",
        ])
    }

    // MARK: summary.md

    func testSummaryWithNarrationAndEvents() {
        let report = report(transcript: [segment(1, "Look at this total."), segment(6, "It should be 42.")], events: sampleEvents)
        XCTAssertEqual(report.summary, """
        # Report: Look at this total.

        - App: Safari
        - Window: Checkout
        - Page: https://shop.example/checkout
        - macOS: 27.0.1
        - Screen: 1512×982 points at 2x
        - Recording: 3024×1964 px, 0:10
        - Recorded area: 1000×600 points
        - Date: \(recordedAt.formatted(date: .long, time: .shortened))

        ## Keyframes

        Each keyframe `#N [time]` has what was said while it was on screen, then what happened, with the time of each event. Positions are points from the top-left corner of the recorded area.

        - #1 [0:00] "Look at this total."
          - 0:00 In Safari, window "Checkout"
        - #2 [0:02] (nothing said)
          - 0:02 Clicked button "Pay" at 412, 300
          - 0:03 Pressed ⌘R
        - #3 [0:04] "It should be 42."
          - 0:04 Drew a red arrow at the top right, pointing at 790, 50 (mark 1)
        - #4 [0:08] (nothing said)
          - 0:08 Switched to window "Receipt" in Safari

        ## For an AI agent

        The user recorded the screen while talking, to show you something and ask for something. What they said is the request; the clicks, shortcuts and app switches are what they did; the drawings mark what they are pointing at.
        Look at the contact sheet first: every keyframe in one picture, numbered #N as above. Then open the frames you need by number: `frames/frame-03.png` is #3 (PNG files your Read tool can open). Red strokes, arrows, boxes and highlights are the user's drawings and point at what matters. For a closer look at a moment (something that moves, or happens between keyframes), run `screenme zoom "/Users/me/Desktop/Report 1" --at 0:12` (or `--phrase "words they said"`, or `--mark N`): it prints the path of a grid of frames around it. If the request is still unclear, ask the user before you change anything.

        - Contact sheet: `/Users/me/Desktop/Report 1/contact-sheet.png`
        - Frames: `/Users/me/Desktop/Report 1/frames` (`frame-01.png` to `frame-04.png`)
        - Video: `/Users/me/Desktop/Report 1/recording.mp4`
        - Manifest: `/Users/me/Desktop/Report 1/report.json` (every word with its time, the events, marks and windows)

        """)
    }

    func testSummaryWithoutEventsOrNarrationSaysWhy() {
        let summary = report(transcript: [], events: nil, duration: 4).summary
        XCTAssertTrue(summary.hasPrefix("# Report: Safari\n"))
        XCTAssertTrue(summary.contains("No narration. The recording has no audio.\n\n- #1 [0:00] (the start)\n"))
        XCTAssertTrue(summary.contains("without narration"))
        XCTAssertFalse(summary.contains("Recorded area"))
        XCTAssertFalse(summary.contains("Cropped to"))
    }

    func testManifestHasKeyframesMarksWordsAndEvents() throws {
        let report = report(transcript: [segment(1, "Look at this total."), segment(6, "It should be 42.")], events: sampleEvents,
                            crops: [1: AutoCrop.Crop(rect: CGRect(x: 0, y: 0, width: 600, height: 400), apps: ["Safari"])])
        let manifest = report.manifest
        XCTAssertEqual(manifest.keyframes.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(manifest.keyframes.map(\.file), ["frames/frame-01.png", "frames/frame-02.png", "frames/frame-03.png", "frames/frame-04.png"])
        XCTAssertEqual(manifest.keyframes[1].fullFile, "frames-full/frame-02.png")
        XCTAssertEqual(manifest.keyframes[1].crop, ReportManifest.Crop(rect: ReportManifest.Rect(x: 0, y: 0, width: 600, height: 400), apps: ["Safari"]))
        XCTAssertNil(manifest.keyframes[0].crop)
        XCTAssertEqual(manifest.keyframes[1].events.map(\.text), ["Clicked button \"Pay\" at 412, 300", "Pressed ⌘R"])
        XCTAssertEqual(manifest.keyframes[2].text, "It should be 42.")
        XCTAssertEqual(manifest.marks, [ReportManifest.Mark(number: 1, time: 4, kind: .drawing, tool: .arrow, color: .red,
                                                            box: RecordingEvent.Box(x: 600, y: 40, width: 200, height: 100),
                                                            x: 790, y: 50, keyframe: 3)])
        XCTAssertEqual(manifest.transcript.words.count, 8)
        XCTAssertEqual(manifest.transcript.segments.count, 2)
        XCTAssertNil(manifest.transcript.noNarration)
        XCTAssertEqual(manifest.events.count, 5)
        XCTAssertEqual(manifest.croppedTo, "Safari")
        XCTAssertEqual(manifest.contactSheetFull, "contact-sheet-full.png")
        XCTAssertEqual(manifest.area, ReportManifest.Size(width: 1000, height: 600))
        XCTAssertEqual(try ReportManifest.decode(manifest.json()), manifest)

        // The environment is typed fields; summary.md formats them.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest.json()) as? [String: Any])
        let environment = try XCTUnwrap(json["environment"] as? [String: Any])
        XCTAssertEqual(environment["date"] as? String, "2026-10-21T08:22:00Z")
        XCTAssertEqual(environment["video"] as? NSDictionary, ["width": 3024, "height": 1964, "duration": 10])
        XCTAssertEqual(environment["screen"] as? NSDictionary, ["width": 1512, "height": 982, "scale": 2])
        XCTAssertEqual(json["version"] as? Int, 2)
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
        let sidecar = Sidecar.events.url(for: video)
        XCTAssertEqual(sidecar.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(sidecar.lastPathComponent, ".Screenme 2026-10-21 at 10.22.33.mp4.events.json")

        RecordingEvents.record(sampleEvents, for: video)
        XCTAssertEqual(try JSONDecoder().decode(RecordingEvents.self, from: Data(contentsOf: sidecar)), sampleEvents)
        let listed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        XCTAssertTrue(listed.isEmpty, "a listing that skips hidden files never sees the sidecar")

        // A recording from an earlier launch: only the sidecar knows its events.
        let older = directory.appendingPathComponent("older.mp4")
        try sampleEvents.json().write(to: Sidecar.events.url(for: older))
        XCTAssertEqual(RecordingEvents.events(for: older), sampleEvents)
        XCTAssertNil(RecordingEvents.events(for: directory.appendingPathComponent("none.mp4")))

    }

    // MARK: Folder

    func testSamplesAVideoAtTwoFramesASecond() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 3)
        let samples = try await FrameSampler.samples(of: AVURLAsset(url: video), duration: 3)
        XCTAssertEqual(samples.map(\.time), [0, 0.5, 1, 1.5, 2, 2.5])
        XCTAssertEqual(samples.first?.width, 64)
        XCTAssertEqual(samples.first?.height, 48)
    }

    func testWritesFolderFromASilentRecording() async throws {
        let directory = try Self.temporaryDirectory()
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       [report.folder.lastPathComponent, "input.mp4"], "built in a hidden folder that was moved into place")
        XCTAssertEqual(ReportLayout.latest(in: directory)?.lastPathComponent, report.folder.lastPathComponent)
        // The video only gets brighter: a change, but every picture looks the same as the start's.
        XCTAssertEqual(report.keyframes.map(\.reason), [.start, .drawing])
        XCTAssertEqual(report.keyframes[1].time, 1.2, accuracy: 0.001)
        let files = FileManager.default
        XCTAssertTrue(files.fileExists(atPath: report.folder.appendingPathComponent("recording.mp4").path))
        let image = try XCTUnwrap(NSImage(contentsOf: report.folder.appendingPathComponent("frames/frame-02.png")))
        XCTAssertEqual(image.size, CGSize(width: 320, height: 240))
        let sheet = try XCTUnwrap(NSImage(contentsOf: report.folder.appendingPathComponent("contact-sheet.png")))
        XCTAssertEqual(sheet.size, ContactSheet.layout(count: 2, boxHeight: 480).size)
        let manifest = try ReportManifest.decode(Data(contentsOf: report.folder.appendingPathComponent("report.json")))
        XCTAssertEqual(manifest, report.manifest)
        XCTAssertEqual(manifest.events, events.events)
        XCTAssertEqual(manifest.environment.video.duration, 3, accuracy: 0.01)
        let summary = try String(contentsOf: report.folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertEqual(summary, report.summary)
        XCTAssertTrue(summary.contains("No narration. The recording has no audio."))
        XCTAssertTrue(summary.contains("- App: Notes\n- Window: Ideas\n"))
        XCTAssertTrue(summary.contains("- Recording: 320×240 px, 0:03"))
        XCTAssertTrue(summary.contains("- #2 [0:01] (nothing said)\n  - 0:01 Drew a red rectangle at the top left (10, 10, 100×50) (mark 1)"))
        let listed = try FileManager.default.contentsOfDirectory(atPath: report.folder.path).sorted()
        XCTAssertEqual(listed, ["contact-sheet.png", "frames", "recording.mp4", "report.json", "summary.md"])

        // Pasted into a chat it is the contact sheet; into a terminal, the summary.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AIReportTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        AIReporter.copy(report, to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), report.summary)
        XCTAssertEqual(pasteboard.data(forType: .png), try Data(contentsOf: report.folder.appendingPathComponent("contact-sheet.png")))

        // A second report from the same second gets its own folder.
        let again = try await AIReporter.write(video, context: CaptureContext(), events: nil, recordedAt: Date(), in: directory)
        XCTAssertNotEqual(again.folder, report.folder)
        XCTAssertNil(again.manifest.area)
        XCTAssertEqual(again.keyframes.map(\.time), [0.3])
    }

    /// A report that fails once its hidden folder holds files (here the keyframes cannot be written) leaves nothing behind.
    func testAFailedReportLeavesNothingBehind() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 1)
        do {
            _ = try await AIReporter.write(video, context: CaptureContext(), events: nil, recordedAt: Date(), in: directory) { value in
                // The video is copied in; from now on the frames folder takes no files.
                guard value == 0.1, let building = Self.building(in: directory) else { return }
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: building.appendingPathComponent("frames").path)
            }
            XCTFail("a report whose keyframes cannot be written fails")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown, "it failed writing a keyframe: \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["input.mp4"])
    }

    /// The folder's name is settled when it moves into place: when the name was taken while the report was built
    /// (another report made in the same second), it gets a number, and its summary names the folder it ended up in.
    func testAReportWhoseNameIsTakenWhileItIsBuiltGetsANumber() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 1)
        let report = try await AIReporter.write(video, context: CaptureContext(), events: nil, recordedAt: Date(), in: directory) { value in
            // ".Report 2026-10-21 at 10.22.33 <UUID>" is being built: another folder takes "Report 2026-10-21 at 10.22.33".
            guard value == 0.1, let building = Self.building(in: directory) else { return }
            let name = String(building.lastPathComponent.dropFirst().dropLast(UUID().uuidString.count + 1))
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let name = report.folder.lastPathComponent
        XCTAssertTrue(name.hasPrefix("Report ") && name.hasSuffix(" 2"), name)
        let taken = String(name.dropLast(2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), [taken, name, "input.mp4"].sorted())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(taken).path), [],
                       "the other folder is left alone")
        let summary = try String(contentsOf: report.folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertEqual(summary, report.summary)
        XCTAssertTrue(summary.contains("- Contact sheet: `\(report.folder.path)/contact-sheet.png`"), summary)
    }

    /// Hidden folders of reports a crash left half built go once they are a day old; nothing else in the save folder does.
    func testFoldersACrashLeftHalfBuiltAreRemovedAfterADay() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = directory.appendingPathComponent(".Report 2026-10-19 at 09.00.00 \(UUID().uuidString)")
        let building = directory.appendingPathComponent(".Report 2026-10-21 at 09.00.00 \(UUID().uuidString)")
        let report = directory.appendingPathComponent("Report 2026-10-19 at 10.00.00")
        let hidden = directory.appendingPathComponent(".notes")
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        for folder in [abandoned, building, report, hidden] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if folder != building { try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: folder.path) }
        }

        AIReporter.removeAbandoned(in: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       [hidden, building, report].map(\.lastPathComponent).sorted())
    }

    func testCropsKeyframesOfAScreenRecordingAndKeepsTheFullFrames() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 3)
        let events = RecordingEvents(width: 320, height: 240, events: [.click(at: CGPoint(x: 50, y: 50), time: 1)],
                                     windows: [WindowSnapshot(time: 0, windows: [
                                         WindowSnapshot.Window(app: "Notes", title: "Ideas", x: 10, y: 10, width: 100, height: 80),
                                     ])])

        let report = try await AIReporter.write(video, context: CaptureContext(), events: events, recordedAt: Date(), in: directory)
        XCTAssertEqual(report.keyframes.map(\.crop), [nil, AutoCrop.Crop(rect: CGRect(x: 0, y: 0, width: 320, height: 114), apps: ["Notes"])])
        func size(_ name: String) throws -> CGSize { try XCTUnwrap(NSImage(contentsOf: report.folder.appendingPathComponent(name))).size }
        XCTAssertEqual(try size("frames/frame-02.png"), CGSize(width: 320, height: 114))
        XCTAssertEqual(try size("frames-full/frame-02.png"), CGSize(width: 320, height: 240))
        XCTAssertEqual(try size("frames/frame-01.png"), CGSize(width: 320, height: 240))
        XCTAssertEqual(try size("contact-sheet-full.png"), ContactSheet.layout(count: 2, boxHeight: 480).size)
        XCTAssertTrue(report.summary.contains("\nCropped to: Notes (full frames in frames-full/)\n"))
        XCTAssertTrue(report.summary.contains("- Uncropped frames: `\(report.folder.path)/frames-full`"))

        let whole = try await AIReporter.write(video, context: CaptureContext(), events: events, recordedAt: Date(), autoCrop: false, in: directory)
        XCTAssertFalse(whole.isCropped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: whole.folder.appendingPathComponent("frames-full").path))
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The hidden folder a report is being built in.
    nonisolated static func building(in directory: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(".Report ") }
    }

    /// A gray H.264 video with no audio track, 10 frames a second, a little brighter every frame.
    nonisolated static func writeSilentVideo(to url: URL, seconds: Int) async throws {
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
