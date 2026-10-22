import AVFoundation
import CoreGraphics
import Foundation

/// A Report for AI folder, read through its `report.json` (`ReportManifest`, the type the app writes), for agents
/// that want a closer look than the keyframes: a contact sheet of frames around a moment (`zoom`), plain frames of a
/// stretch (`frames`), or the summary (`inspect`). Everything it writes goes into the folder's `zoom/`.
struct ReportBundle {
    /// Where to look: a time, something the user said, or a mark they drew.
    enum Moment: Equatable {
        case at(Double)
        case phrase(String)
        case mark(Int)
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case notAReport(String)
        case noReports(String)
        case noVideo(String)
        case phraseNotFound(String)
        case markNotFound(Int, count: Int)

        var description: String {
            switch self {
            case .notAReport(let path): "\(path) is not a Report for AI folder (no \(ReportLayout.manifest))"
            case .noReports(let path): "there are no reports yet in \(path). Make one with Report for AI on a recording."
            case .noVideo(let path): "the report's video is missing: \(path)"
            case .phraseNotFound(let phrase): "nobody said \"\(phrase)\" in this recording"
            case .markNotFound(let number, let count): count == 0 ? "this recording has no marks" : "there is no mark \(number); marks go from 1 to \(count)"
            }
        }
    }

    let url: URL
    let manifest: ReportManifest

    init(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(ReportLayout.manifest)) else {
            throw Failure.notAReport(url.path)
        }
        self.url = url
        manifest = try JSONDecoder().decode(ReportManifest.self, from: data)
    }

    /// `latest` is the newest report in `reports`; anything else is a path to a report folder.
    static func open(_ argument: String, reports: URL) throws -> ReportBundle {
        if argument == "latest" {
            guard let latest = ReportLayout.latest(in: reports) else { throw Failure.noReports(reports.path) }
            return try ReportBundle(latest)
        }
        return try ReportBundle(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath, isDirectory: true))
    }

    var summary: String {
        get throws { try String(contentsOf: url.appendingPathComponent(manifest.summary), encoding: .utf8) }
    }

    /// `report.json` as it is on disk.
    var manifestText: String {
        get throws { try String(contentsOf: url.appendingPathComponent(ReportLayout.manifest), encoding: .utf8) }
    }

    var video: URL { url.appendingPathComponent(manifest.video) }
    var contactSheet: URL { url.appendingPathComponent(manifest.contactSheet) }

    // MARK: Moments

    /// The time of a moment in seconds of the video.
    func time(of moment: Moment) throws -> Double {
        switch moment {
        case .at(let seconds):
            return min(max(seconds, 0), manifest.duration)
        case .mark(let number):
            guard let mark = manifest.marks.first(where: { $0.number == number }) else {
                throw Failure.markNotFound(number, count: manifest.marks.count)
            }
            return mark.time
        case .phrase(let phrase):
            guard let time = Self.time(of: phrase, in: manifest.transcript) else { throw Failure.phraseNotFound(phrase) }
            return time
        }
    }

    /// When `phrase` was said: the start of the first run of words that match it (the last word may be cut short),
    /// else the start of a segment that contains it. Case and punctuation do not matter.
    static func time(of phrase: String, in transcript: ReportManifest.Transcript) -> Double? {
        let wanted = tokens(phrase)
        guard !wanted.isEmpty else { return nil }
        let words = transcript.words.map { tokens($0.text).joined(separator: " ") }
        if words.count >= wanted.count {
            for start in 0...(words.count - wanted.count) {
                let matches = wanted.indices.allSatisfy { index in
                    let word = words[start + index]
                    return index == wanted.count - 1 ? word.hasPrefix(wanted[index]) : word == wanted[index]
                }
                if matches { return transcript.words[start].start }
            }
        }
        let joined = wanted.joined(separator: " ")
        return transcript.segments.first { tokens($0.text).joined(separator: " ").contains(joined) }?.start
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// What was said between `from` and `to`.
    func said(from: Double, to: Double) -> String {
        manifest.transcript.words.filter { $0.end > from && $0.start < to }.map(\.text).joined(separator: " ")
    }

    /// "1:05", "0:12.5", "12.5", "1:02:03": seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: Zoom

    struct Zoom {
        var image: URL
        var center: Double
        var times: [Double]
        var said: String

        /// What the command prints: the image, the time of each cell, and what was said.
        var text: String {
            let cells = times.enumerated().map { "#\($0.offset + 1) \(Duration.format($0.element, tenths: true))" }
            var lines = [image.path, "Around \(Duration.format(center, tenths: true)): " + cells.joined(separator: ", ")]
            lines.append(said.isEmpty ? "Nothing was said then." : "Said then: \"\(said)\"")
            return lines.joined(separator: "\n")
        }
    }

    /// Writes a contact sheet of `columns` × `rows` frames from the video around `moment` to `zoom/` and returns it,
    /// each cell captioned with what was said from its time to the next. The frames cover `span` seconds, a quarter of
    /// it before the moment, so what led up to it shows as well as what followed.
    func zoom(_ moment: Moment, span: Double = 2, columns: Int = 3, rows: Int = 3) async throws -> Zoom {
        let center = try time(of: moment)
        let count = max(columns * rows, 1)
        let last = max(manifest.duration - 0.05, 0)
        let start = min(max(center - span / 4, 0), max(last - span, 0))
        let times = (0..<count).map { min(start + (count == 1 ? 0 : span * Double($0) / Double(count - 1)), last) }
        let step = count == 1 ? span : span / Double(count - 1)
        let images = try await frames(at: times, maxSide: Int(ContactSheet.thumbnailWidth) * 2)
        let cells = times.enumerated().map { index, time in
            ContactSheet.Cell(image: ContactSheet.thumbnail(images[index]), number: index + 1, time: time,
                              caption: said(from: time, to: index + 1 < times.count ? times[index + 1] : time + step))
        }
        guard let sheet = ContactSheet.render(cells, columns: columns, tenths: true) else { throw CocoaError(.fileWriteUnknown) }
        let file = try zoomFolder().appendingPathComponent(String(format: "zoom-%.2fs-%gs-%dx%d.png", center, span, columns, rows))
        try sheet.writePNG(to: file)
        return Zoom(image: file, center: center, times: times, said: said(from: times.first ?? center, to: times.last ?? center))
    }

    /// Writes the frames from `from` to `to` seconds, `fps` a second, to `zoom/frames-…/` and returns their files.
    func frames(from: Double, to: Double, fps: Double = 4) async throws -> [URL] {
        let last = max(manifest.duration - 0.05, 0)
        let start = min(max(from, 0), last), end = min(max(to, start), last)
        let step = 1 / max(fps, 0.1)
        let times = Array(stride(from: start, through: end + 0.0001, by: step).prefix(600))
        let folder = try zoomFolder().appendingPathComponent(String(format: "frames-%.2fs-%.2fs", start, end), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, image) in try await frames(at: times, maxSide: 1920).enumerated() {
            let label = Duration.format(times[index], tenths: true).replacingOccurrences(of: ":", with: "m")
            let file = folder.appendingPathComponent(String(format: "frame-%04d-%@.png", index + 1, label))
            try image.writePNG(to: file)
            files.append(file)
        }
        return files
    }

    private func zoomFolder() throws -> URL {
        let folder = url.appendingPathComponent(ReportLayout.zoom, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func frames(at times: [Double], maxSide: Int) async throws -> [CGImage] {
        guard FileManager.default.fileExists(atPath: video.path) else { throw Failure.noVideo(video.path) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for time in times {
            images.append(try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        }
        return images
    }
}
