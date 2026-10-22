import AppKit
import AVFoundation

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
                                         recordedAt: item.date, screen: mainScreen(), autoCrop: Prefs[Pref.reportAutoCrop],
                                         in: Storage.saveDirectory) { value in
                Task { @MainActor in toast.update(value) }
            }
            copy(report)
            NSWorkspace.shared.activateFileViewerSelecting([report.folder.appendingPathComponent(ReportLayout.summary)])
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
        if let sheet = try? Data(contentsOf: report.folder.appendingPathComponent(ReportLayout.contactSheet)) {
            entry.setData(sheet, forType: .png)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
    }

    /// The main screen, for the report's environment.
    @MainActor
    static func mainScreen() -> AIReport.Environment.Screen? {
        NSScreen.main.map { AIReport.Environment.Screen(width: $0.frame.width, height: $0.frame.height, scale: $0.backingScaleFactor) }
    }

    /// Writes the report folder for `video` inside `parent` and returns the report. The folder is built as a hidden
    /// sibling and moved into place when it is complete, so a `Report …` folder is never half written; a failure
    /// leaves nothing behind, and hidden folders a crash left there are removed after a day. Asks for speech
    /// recognition only when the video has sound. Not on the main actor: copying, decoding and writing PNGs take a while.
    static func write(_ video: URL, context: CaptureContext, events: RecordingEvents?, recordedAt date: Date,
                      screen: AIReport.Environment.Screen? = nil, autoCrop: Bool = true, in parent: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AIReport {
        removeAbandoned(in: parent)
        let name = ReportLayout.folderName(at: Date())
        let building = parent.appendingPathComponent(".\(name) \(UUID().uuidString)", isDirectory: true)
        do {
            let report = try await build(video, into: building, context: context, events: events, recordedAt: date,
                                         screen: screen, autoCrop: autoCrop, progress: progress)
            return try place(report, from: building, named: name, in: parent)
        } catch {
            try? FileManager.default.removeItem(at: building)
            throw error
        }
    }

    /// Writes the report's files into `building`, all but the summary, which names the folder they end up in.
    private static func build(_ video: URL, into building: URL, context: CaptureContext, events: RecordingEvents?,
                              recordedAt date: Date, screen: AIReport.Environment.Screen?, autoCrop: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> AIReport {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: video])
        }
        let natural = try await track.load(.naturalSize).applying(track.load(.preferredTransform))

        try FileManager.default.createDirectory(at: building.appendingPathComponent(ReportLayout.frames), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: building.appendingPathComponent(ReportLayout.video))
        progress(0.1)

        // What was said, and small pictures of the whole video for the screen changes, worked out side by side.
        async let spoken = narration(of: asset)
        async let sampled = FrameSampler.samples(of: asset, duration: duration)
        let said = try await spoken
        let samples = try await sampled
        progress(0.75)

        var keyframes = Keyframes.select(words: said.transcript.words, events: events, samples: samples, duration: duration)
        if autoCrop, let events {
            for (index, crop) in AutoCrop.crops(for: keyframes, events: events).enumerated() { keyframes[index].crop = crop }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let environment = AIReport.Environment(
            app: context.app, window: context.window, page: context.page,
            system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", screen: screen,
            video: AIReport.Environment.Video(width: Int(abs(natural.width)), height: Int(abs(natural.height)), duration: duration),
            // Whole seconds, as report.json keeps it.
            date: Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down)))
        let report = AIReport(folder: building, environment: environment, narration: said, recording: events, keyframes: keyframes)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Cropped frames are cut from the full-size picture, so their text stays sharp.
        generator.maximumSize = report.isCropped ? .zero : CGSize(width: maxFrameSide, height: maxFrameSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if report.isCropped {
            try FileManager.default.createDirectory(at: building.appendingPathComponent(ReportLayout.fullFrames), withIntermediateDirectories: true)
        }
        var cells: [ContactSheet.Cell] = [], fullCells: [ContactSheet.Cell] = []
        for (index, keyframe) in report.keyframes.enumerated() {
            let decoded = try await generator.image(at: CMTime(seconds: keyframe.time, preferredTimescale: 600)).image
            let full = decoded.scaledDown(maxWidth: maxFrameSide, maxHeight: maxFrameSide)
            var frame = full
            if report.isCropped {
                try full.writePNG(to: building.appendingPathComponent(ReportLayout.fullFrame(index)))
                fullCells.append(ContactSheet.Cell(image: ContactSheet.thumbnail(full), number: index + 1, time: keyframe.time,
                                                   caption: report.caption(index)))
                if let crop = keyframe.crop, let area = report.area, let cut = cropped(decoded, to: crop.rect, area: area) {
                    frame = cut.scaledDown(maxWidth: maxFrameSide, maxHeight: maxFrameSide)
                }
            }
            try frame.writePNG(to: building.appendingPathComponent(ReportLayout.frame(index)))
            cells.append(ContactSheet.Cell(image: ContactSheet.thumbnail(frame), number: index + 1, time: keyframe.time,
                                           caption: report.caption(index)))
            progress(0.75 + 0.2 * Double(index + 1) / Double(report.keyframes.count))
        }
        if let sheet = ContactSheet.render(cells) {
            try sheet.writePNG(to: building.appendingPathComponent(ReportLayout.contactSheet))
        }
        if let sheet = ContactSheet.render(fullCells) {
            try sheet.writePNG(to: building.appendingPathComponent(ReportLayout.fullContactSheet))
        }

        try report.manifest.json().write(to: building.appendingPathComponent(ReportLayout.manifest))
        return report
    }

    /// Moves the report built in `building` to `name` in `parent`, or `name 2`, `name 3`… when that is taken, writing
    /// the summary for the folder it is about to become. The name is settled at the move, so two reports made in the
    /// same second both arrive.
    private static func place(_ built: AIReport, from building: URL, named name: String, in parent: URL) throws -> AIReport {
        var report = built
        var number = 1
        while true {
            report.folder = parent.appendingPathComponent(number == 1 ? name : "\(name) \(number)", isDirectory: true)
            try report.summary.write(to: building.appendingPathComponent(ReportLayout.summary), atomically: true, encoding: .utf8)
            do {
                try FileManager.default.moveItem(at: building, to: report.folder)
                return report
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    /// Removes the hidden folders of reports a crash left half built in `parent`, once they have not changed for
    /// `age`: a report being built now is never touched.
    static func removeAbandoned(in parent: URL, olderThan age: TimeInterval = 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix("." + ReportLayout.folderPrefix) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Frames are large enough to read any text on screen, small enough for an agent to look at a couple of dozen.
    static let maxFrameSide = 1920

    /// The part of a frame of a recorded `area` (points) inside `rect` (points from its top-left corner).
    static func cropped(_ image: CGImage, to rect: CGRect, area: CGSize) -> CGImage? {
        guard area.width > 0, area.height > 0 else { return nil }
        let sx = CGFloat(image.width) / area.width, sy = CGFloat(image.height) / area.height
        let pixels = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels.isEmpty ? nil : image.cropping(to: pixels)
    }

    /// What was said, or why there is nothing.
    private static func narration(of asset: AVURLAsset) async throws -> Narration {
        guard let audio = try await audioFile(of: asset) else { return .silent("The recording has no audio.") }
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            let transcript = try await Transcription.transcribe(audio)
            return transcript.segments.isEmpty ? .silent("No speech was recognized in the recording.") : .spoken(transcript)
        } catch {
            return .silent("The narration could not be transcribed: \(error.localizedDescription)")
        }
    }

    /// The sound of the recording as a temporary M4A file, which both speech APIs read. Nil without an audio track.
    private static func audioFile(of asset: AVURLAsset) async throws -> URL? {
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try await session.export(to: url, as: .m4a)
        return url
    }
}
