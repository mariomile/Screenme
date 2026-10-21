import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Report for AI: turns a recording, what was said and what happened during it into a folder in the save folder
/// (the video, key frames, `events.json` and `report.md`) and copies the report, with absolute paths, ready to paste
/// into an agent, GitHub or Linear.
@MainActor
enum AIReporter {
    /// Makes the report, copies it and shows the folder. Returns false when it failed, which an alert says.
    static func make(_ item: CaptureItem) async -> Bool {
        let toast = Toast.progress("Creating report for AI")
        defer { toast.finish() }
        do {
            let context = await CaptureContexts.context(for: item.url)
            let report = try await write(item.url, context: context, events: RecordingEvents.events(for: item.url),
                                         recordedAt: item.date, in: Storage.saveDirectory) {
                toast.update($0)
            }
            Clipboard.copyText(report.markdown(absoluteLinks: true))
            NSWorkspace.shared.activateFileViewerSelecting([report.folder.appendingPathComponent("report.md")])
            return true
        } catch {
            CaptureCoordinator.shared.report(error)
            return false
        }
    }

    /// Writes the report folder for `video` inside `parent` and returns the report. Asks for speech recognition
    /// only when the video has sound.
    static func write(_ video: URL, context: CaptureContext, events: RecordingEvents?, recordedAt date: Date, in parent: URL,
                      progress: (Double) -> Void = { _ in }) async throws -> AIReport {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: video])
        }
        let natural = try await track.load(.naturalSize).applying(track.load(.preferredTransform))

        let folder = newFolder(in: parent)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: folder.appendingPathComponent(AIReport.videoName))
        if let events { try events.json().write(to: folder.appendingPathComponent(AIReport.eventsName)) }
        progress(0.1)

        var transcript: [TranscriptSegment] = []
        var noNarration = "No speech was recognized in the recording."
        if let audio = try await audioFile(of: asset) {
            defer { try? FileManager.default.removeItem(at: audio) }
            do {
                transcript = try await Transcription.transcribe(audio)
            } catch {
                noNarration = "The narration could not be transcribed: \(error.localizedDescription)"
            }
        } else {
            noNarration = "The recording has no audio."
        }
        progress(0.7)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let screen = NSScreen.main.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) points at \(Int($0.backingScaleFactor))x" }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let environment = AIReport.Environment(
            app: context.app, window: context.window, page: context.page,
            system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", screen: screen,
            video: "\(Int(abs(natural.width)))×\(Int(abs(natural.height))) px, \(Duration.format(duration))",
            date: dateFormatter.string(from: date))
        var report = AIReport(folder: folder, environment: environment, transcript: transcript, noNarration: noNarration, events: events)
        report.makeTimeline(duration: duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Large enough to read any text on screen, small enough for an agent to look at a dozen of them.
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, time) in report.frameTimes.enumerated() {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            try writePNG(image, to: folder.appendingPathComponent(AIReport.frameName(index)))
            progress(0.7 + 0.3 * Double(index + 1) / Double(report.frameTimes.count))
        }

        try report.markdown(absoluteLinks: false).write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return report
    }

    /// `Report 2026-10-21 at 10.22.33`, with a number when that name is taken.
    private static func newFolder(in parent: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Report \(formatter.string(from: Date()))"
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        return url
    }

    /// The sound of the recording as a temporary M4A file, which both speech APIs read. Nil without an audio track.
    private static func audioFile(of asset: AVURLAsset) async throws -> URL? {
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try await session.export(to: url, as: .m4a)
        return url
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
