import AVFoundation
import XCTest
@testable import Screenme

/// Bug Report: narration into steps, where the frames go, report.md, and the folder made from a real (silent) video.
@MainActor
final class BugReportTests: XCTestCase {
    private func segment(_ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text)
    }

    private func report(transcript: [TranscriptSegment], frameTimes: [Double]) -> BugReport {
        let environment = BugReport.Environment(app: "Safari", window: "Checkout", page: "https://shop.example/checkout",
                                                system: "27.0.1", screen: "1512×982 points at 2x",
                                                video: "3024×1964 px, 0:12", date: "21 October 2026 at 10:22")
        return BugReport(folder: URL(fileURLWithPath: "/Users/me/Desktop/Bug Report 1", isDirectory: true),
                         environment: environment, transcript: transcript,
                         noNarration: "The recording has no audio.", frameTimes: frameTimes)
    }

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

    func testOneStepPerSegmentUpToEight() {
        let segments = (0..<3).map { segment(Double($0 * 5), "Part \($0)") }
        XCTAssertEqual(BugReport.steps(from: segments), segments.map { BugReport.Step(time: $0.start, text: $0.text) })
    }

    func testMoreThanEightSegmentsMergeIntoEightSteps() {
        let segments = (0..<20).map { segment(Double($0), "s\($0)") }
        let steps = BugReport.steps(from: segments)
        XCTAssertEqual(steps.count, 8)
        XCTAssertEqual(steps.first, BugReport.Step(time: 0, text: "s0 s1"))
        XCTAssertEqual(steps.last, BugReport.Step(time: 17, text: "s17 s18 s19"))
        XCTAssertEqual(steps.map(\.text).joined(separator: " "), segments.map(\.text).joined(separator: " "))
    }

    // MARK: Frames

    func testFramesAtStepStartsStayInsideTheVideo() {
        let steps = [BugReport.Step(time: -0.2, text: "a"), BugReport.Step(time: 4, text: "b"), BugReport.Step(time: 12, text: "c")]
        XCTAssertEqual(BugReport.frameTimes(for: steps, duration: 10), [0, 4, 9.9])
    }

    func testWithoutNarrationFramesAreSpreadEvenly() {
        XCTAssertEqual(BugReport.frameTimes(for: [], duration: 4), [1, 3])
        XCTAssertEqual(BugReport.frameTimes(for: [], duration: 0.5), [0.25])
        let long = BugReport.frameTimes(for: [], duration: 80)
        XCTAssertEqual(long.count, 8)
        XCTAssertEqual(long.first, 5)
        XCTAssertEqual(long.last, 75)
    }

    // MARK: report.md

    func testReportWithNarration() {
        let transcript = [segment(0, "I open the cart and press Pay."), segment(5, "The button spins forever.")]
        let report = report(transcript: transcript, frameTimes: [0, 5])
        XCTAssertEqual(report.markdown(absoluteLinks: false), """
        # Bug report: I open the cart and press Pay.

        ## Environment

        - App: Safari
        - Window: Checkout
        - Page: https://shop.example/checkout
        - macOS: 27.0.1
        - Screen: 1512×982 points at 2x
        - Recording: 3024×1964 px, 0:12
        - Date: 21 October 2026 at 10:22

        ## Transcript

        - [0:00] I open the cart and press Pay.
        - [0:05] The button spins forever.

        ## Steps

        1. [0:00] I open the cart and press Pay.

           ![Step 1 at 0:00](frames/01.png)

        2. [0:05] The button spins forever.

           ![Step 2 at 0:05](frames/02.png)

        ## Video

        [recording.mp4](recording.mp4)

        ## For an AI coding agent

        Reproduce and fix the bug described above. The user recorded the screen while explaining the problem: the transcript is what they said, and each step has a frame of the screen at that moment.
        Look at every frame before you start (they are PNG files your Read tool can open), find the cause in the code, fix it, and say how you checked the fix.

        - Frame 1 at 0:00: `/Users/me/Desktop/Bug Report 1/frames/01.png`
        - Frame 2 at 0:05: `/Users/me/Desktop/Bug Report 1/frames/02.png`
        - Video: `/Users/me/Desktop/Bug Report 1/recording.mp4`

        """)
    }

    func testClipboardVersionLinksAbsolutePaths() {
        let markdown = report(transcript: [segment(2, "It breaks.")], frameTimes: [2]).markdown(absoluteLinks: true)
        XCTAssertTrue(markdown.contains("![Step 1 at 0:02](</Users/me/Desktop/Bug Report 1/frames/01.png>)"))
        XCTAssertTrue(markdown.contains("[recording.mp4](</Users/me/Desktop/Bug Report 1/recording.mp4>)"))
        XCTAssertFalse(markdown.contains("](frames/"))
    }

    func testReportWithoutNarrationShowsFramesAndSaysWhy() {
        let markdown = report(transcript: [], frameTimes: [1, 3]).markdown(absoluteLinks: false)
        XCTAssertTrue(markdown.hasPrefix("# Bug report: Safari\n"))
        XCTAssertTrue(markdown.contains("## Transcript\n\nNo narration. The recording has no audio.\n"))
        XCTAssertFalse(markdown.contains("## Steps"))
        XCTAssertTrue(markdown.contains("## Frames\n\n![Frame 1 at 0:01](frames/01.png)\n\n![Frame 2 at 0:03](frames/02.png)\n"))
        XCTAssertTrue(markdown.contains("It has no narration: work out what goes wrong from the frames"))
    }

    func testLongFirstSentenceIsShortenedForTheTitle() {
        let long = "When I drag the second card onto the first column the whole board scrolls back to the top and loses it"
        XCTAssertEqual(report(transcript: [segment(0, long)], frameTimes: [0]).title,
                       "Bug report: When I drag the second card onto the first column the whole board scrolls…")
    }

    // MARK: Folder

    func testWritesFolderFromASilentRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BugReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mp4")
        try await Self.writeSilentVideo(to: video, seconds: 3)

        let report = try await BugReporter.write(video, context: CaptureContext(app: "Notes", window: "Ideas"),
                                                 recordedAt: Date(), in: directory)

        XCTAssertEqual(report.folder.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(report.folder.lastPathComponent.hasPrefix("Bug Report "))
        XCTAssertEqual(report.frameTimes, [0.75, 2.25])
        let files = FileManager.default
        XCTAssertTrue(files.fileExists(atPath: report.folder.appendingPathComponent("recording.mp4").path))
        for name in ["frames/01.png", "frames/02.png"] {
            let image = try XCTUnwrap(NSImage(contentsOf: report.folder.appendingPathComponent(name)), name)
            XCTAssertEqual(image.size, CGSize(width: 320, height: 240))
        }
        let markdown = try String(contentsOf: report.folder.appendingPathComponent("report.md"), encoding: .utf8)
        XCTAssertEqual(markdown, report.markdown(absoluteLinks: false))
        XCTAssertTrue(markdown.contains("No narration. The recording has no audio."))
        XCTAssertTrue(markdown.contains("- App: Notes\n- Window: Ideas\n"))
        XCTAssertTrue(markdown.contains("- Recording: 320×240 px, 0:03"))

        // A second report from the same second gets its own folder.
        let again = try await BugReporter.write(video, context: CaptureContext(), recordedAt: Date(), in: directory)
        XCTAssertNotEqual(again.folder, report.folder)
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
