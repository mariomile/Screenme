import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Report for AI: turns a recording, what was said and what happened during it into a folder in the save folder
/// (the contact sheet, keyframes, video, `summary.md` and `report.json`) and copies the summary, with absolute paths,
/// and the contact sheet, ready to paste into an agent, GitHub or Linear. The work runs off the main thread; only the toast and the pasteboard are on it.
enum AIReporter {
    /// Makes the report, copies it and shows the folder. Returns false when it failed, which an alert says.
    @MainActor
    static func make(_ item: CaptureItem) async -> Bool {
        let toast = Toast.progress("Creating report for AI")
        defer { toast.finish() }
        do {
            let context = await CaptureContexts.context(for: item.url)
            let report = try await write(item.url, context: context, events: RecordingEvents.events(for: item.url),
                                         recordedAt: item.date, screen: screenDescription(), autoCrop: Prefs[Pref.reportAutoCrop],
                                         in: Storage.saveDirectory) { value in
                Task { @MainActor in toast.update(value) }
            }
            copy(report)
            NSWorkspace.shared.activateFileViewerSelecting([report.folder.appendingPathComponent(AIReport.summaryName)])
            return true
        } catch {
            CaptureCoordinator.shared.report(error)
            return false
        }
    }

    /// The summary as text and the contact sheet as an image in one pasteboard item: a chat gets the sheet,
    /// a terminal or a text field the summary.
    @MainActor
    static func copy(_ report: AIReport, to pasteboard: NSPasteboard = .general) {
        let entry = NSPasteboardItem()
        entry.setString(report.summary, forType: .string)
        if let sheet = try? Data(contentsOf: report.folder.appendingPathComponent(AIReport.contactSheetName)) {
            entry.setData(sheet, forType: .png)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
    }

    /// "1512×982 points at 2x": the main screen, for the report's environment.
    @MainActor
    static func screenDescription() -> String? {
        NSScreen.main.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) points at \(Int($0.backingScaleFactor))x" }
    }

    /// Writes the report folder for `video` inside `parent` and returns the report. Asks for speech recognition
    /// only when the video has sound. Not on the main actor: copying, decoding and writing PNGs take a while.
    static func write(_ video: URL, context: CaptureContext, events: RecordingEvents?, recordedAt date: Date,
                      screen: String? = nil, autoCrop: Bool = true, in parent: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AIReport {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: video])
        }
        let natural = try await track.load(.naturalSize).applying(track.load(.preferredTransform))

        let folder = newFolder(in: parent)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: folder.appendingPathComponent(AIReport.videoName))
        progress(0.1)

        var transcript = Transcript()
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
        progress(0.6)
        // Small pictures of the whole video, for the screen changes and for telling pictures apart.
        let samples = try await FrameSampler.samples(of: asset, duration: duration)
        progress(0.75)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let environment = AIReport.Environment(
            app: context.app, window: context.window, page: context.page,
            system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", screen: screen,
            video: "\(Int(abs(natural.width)))×\(Int(abs(natural.height))) px, \(Duration.format(duration))",
            date: dateFormatter.string(from: date))
        var report = AIReport(folder: folder, environment: environment, transcript: transcript, noNarration: noNarration, events: events)
        report.makeKeyframes(duration: duration, samples: samples)
        if autoCrop, let events { report.crops = AutoCrop.crops(for: report.keyframes, events: events) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Cropped frames are cut from the full-size picture, so their text stays sharp.
        generator.maximumSize = report.isCropped ? .zero : CGSize(width: maxFrameSide, height: maxFrameSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if report.isCropped {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames-full"), withIntermediateDirectories: true)
        }
        var cells: [ContactSheet.Cell] = [], fullCells: [ContactSheet.Cell] = []
        for (index, keyframe) in report.keyframes.enumerated() {
            let decoded = try await generator.image(at: CMTime(seconds: keyframe.time, preferredTimescale: 600)).image
            let full = fitted(decoded, maxSide: maxFrameSide)
            var frame = full
            if report.isCropped {
                try writePNG(full, to: folder.appendingPathComponent(AIReport.fullFrameName(index)))
                fullCells.append(ContactSheet.Cell(image: ContactSheet.thumbnail(full), number: index + 1, time: keyframe.time,
                                                   caption: report.caption(index)))
                if let crop = report.crops[index], let events,
                   let cut = cropped(decoded, to: crop.rect, area: CGSize(width: events.width, height: events.height)) {
                    frame = fitted(cut, maxSide: maxFrameSide)
                }
            }
            try writePNG(frame, to: folder.appendingPathComponent(AIReport.frameName(index)))
            cells.append(ContactSheet.Cell(image: ContactSheet.thumbnail(frame), number: index + 1, time: keyframe.time,
                                           caption: report.caption(index)))
            progress(0.75 + 0.2 * Double(index + 1) / Double(report.keyframes.count))
        }
        if let sheet = ContactSheet.render(cells) {
            try writePNG(sheet, to: folder.appendingPathComponent(AIReport.contactSheetName))
        }
        if let sheet = ContactSheet.render(fullCells) {
            try writePNG(sheet, to: folder.appendingPathComponent(AIReport.fullContactSheetName))
        }

        try report.manifest.json().write(to: folder.appendingPathComponent(AIReport.manifestName))
        try report.summary.write(to: folder.appendingPathComponent(AIReport.summaryName), atomically: true, encoding: .utf8)
        return report
    }

    /// Frames are large enough to read any text on screen, small enough for an agent to look at a couple of dozen.
    static let maxFrameSide = 1920

    /// `image` scaled down so its long side is at most `maxSide` pixels, or as it is.
    static func fitted(_ image: CGImage, maxSide: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxSide else { return image }
        let scale = Double(maxSide) / Double(long)
        let width = max(Int((Double(image.width) * scale).rounded()), 1), height = max(Int((Double(image.height) * scale).rounded()), 1)
        return CGImage.drawn(width: width, height: height, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        } ?? image
    }

    /// The part of a frame of a recorded `area` (points) inside `rect` (points from its top-left corner).
    static func cropped(_ image: CGImage, to rect: CGRect, area: CGSize) -> CGImage? {
        guard area.width > 0, area.height > 0 else { return nil }
        let sx = CGFloat(image.width) / area.width, sy = CGFloat(image.height) / area.height
        let pixels = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels.isEmpty ? nil : image.cropping(to: pixels)
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

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
