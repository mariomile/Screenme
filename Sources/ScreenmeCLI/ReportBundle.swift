import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Report for AI folder, read through its `report.json`, for agents that want a closer look than the keyframes:
/// a dense grid of frames around a moment (`zoom`), plain frames of a stretch (`frames`), or the summary (`inspect`).
/// Everything it writes goes into the folder's `zoom/`.
struct ReportBundle {
    /// The parts of `report.json` this tool reads. The app writes more.
    struct Manifest: Decodable {
        struct Keyframe: Decodable {
            var number: Int
            var time: Double
            var file: String
            var text: String
        }

        struct Segment: Decodable {
            var start: Double
            var end: Double
            var text: String
        }

        struct Transcript: Decodable {
            var segments: [Segment]
            var words: [Segment]
        }

        struct Mark: Decodable {
            var number: Int
            var time: Double
            var keyframe: Int
        }

        var duration: Double
        var video: String
        var summary: String
        var contactSheet: String
        var keyframes: [Keyframe]
        var transcript: Transcript
        var marks: [Mark]
    }

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
            case .notAReport(let path): "\(path) is not a Report for AI folder (no report.json)"
            case .noReports(let path): "there are no reports yet in \(path). Make one with Report for AI on a recording."
            case .noVideo(let path): "the report's video is missing: \(path)"
            case .phraseNotFound(let phrase): "nobody said \"\(phrase)\" in this recording"
            case .markNotFound(let number, let count): count == 0 ? "this recording has no marks" : "there is no mark \(number); marks go from 1 to \(count)"
            }
        }
    }

    static let manifestName = "report.json"

    let url: URL
    let manifest: Manifest

    init(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.manifestName)) else {
            throw Failure.notAReport(url.path)
        }
        self.url = url
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// `latest` is the newest report in `reports`; anything else is a path to a report folder.
    static func open(_ argument: String, reports: URL) throws -> ReportBundle {
        if argument == "latest" {
            guard let latest = MCPServer.latestReport(in: reports) else { throw Failure.noReports(reports.path) }
            return try ReportBundle(latest)
        }
        return try ReportBundle(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath, isDirectory: true))
    }

    var summary: String {
        get throws { try String(contentsOf: url.appendingPathComponent(manifest.summary), encoding: .utf8) }
    }

    var video: URL { url.appendingPathComponent(manifest.video) }

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
    static func time(of phrase: String, in transcript: Manifest.Transcript) -> Double? {
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

    /// "0:12.4", "1:02:03.0": a time with tenths.
    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        let total = tenths / 10, hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d.%d", hours, minutes, secs, tenths % 10) }
        return String(format: "%d:%02d.%d", minutes, secs, tenths % 10)
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
            var lines = [image.path, "Around \(ReportBundle.format(center)): " + times.enumerated().map { "#\($0.offset + 1) \(ReportBundle.format($0.element))" }.joined(separator: ", ")]
            lines.append(said.isEmpty ? "Nothing was said then." : "Said then: \"\(said)\"")
            return lines.joined(separator: "\n")
        }
    }

    /// Writes a grid of `columns` × `rows` frames from the video around `moment` to `zoom/` and returns it. The frames
    /// cover `span` seconds, a quarter of it before the moment, so what led up to it shows as well as what followed.
    func zoom(_ moment: Moment, span: Double = 2, columns: Int = 3, rows: Int = 3) async throws -> Zoom {
        let center = try time(of: moment)
        let count = max(columns * rows, 1)
        let last = max(manifest.duration - 0.05, 0)
        let start = min(max(center - span / 4, 0), max(last - span, 0))
        let times = (0..<count).map { min(start + (count == 1 ? 0 : span * Double($0) / Double(count - 1)), last) }
        let cellWidth = (Self.gridWidth - Self.gap * CGFloat(columns + 1)) / CGFloat(columns)
        let images = try await frames(at: times, maxSide: Int(cellWidth * 1.5))
        let labels = times.enumerated().map { "#\($0.offset + 1)  \(Self.format($0.element))" }
        guard let grid = Self.grid(images, labels: labels, columns: columns, cellWidth: cellWidth) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try zoomFolder().appendingPathComponent(String(format: "zoom-%.2fs-%gs-%dx%d.png", center, span, columns, rows))
        try Self.writePNG(grid, to: file)
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
            let file = folder.appendingPathComponent(String(format: "frame-%04d-%@.png", index + 1, Self.format(times[index]).replacingOccurrences(of: ":", with: "m")))
            try Self.writePNG(image, to: file)
            files.append(file)
        }
        return files
    }

    private func zoomFolder() throws -> URL {
        let folder = url.appendingPathComponent("zoom", isDirectory: true)
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

    // MARK: Drawing

    static let gridWidth: CGFloat = 1920
    static let gap: CGFloat = 12

    /// The images in a grid on a dark background, each with its label in a chip at the top left.
    static func grid(_ images: [CGImage], labels: [String], columns: Int, cellWidth: CGFloat) -> CGImage? {
        guard let first = images.first, first.width > 0 else { return nil }
        let cellHeight = (cellWidth * CGFloat(first.height) / CGFloat(first.width)).rounded()
        let rows = (images.count + columns - 1) / columns
        let width = Int(gap * CGFloat(columns + 1) + cellWidth * CGFloat(columns))
        let height = Int(gap * CGFloat(rows + 1) + cellHeight * CGFloat(rows))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 20, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            // Top-left layout into the context's bottom-left space.
            let cell = CGRect(x: gap + CGFloat(column) * (cellWidth + gap),
                              y: CGFloat(height) - gap - CGFloat(row + 1) * cellHeight - CGFloat(row) * gap,
                              width: cellWidth, height: cellHeight)
            context.draw(image, in: cell)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: labels[index], attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let chip = CGRect(x: cell.minX + 8, y: cell.maxY - 8 - 34, width: textWidth + 20, height: 34)
            context.setFillColor(CGColor(gray: 0, alpha: 0.75))
            context.addPath(CGPath(roundedRect: chip, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
            context.textPosition = CGPoint(x: chip.minX + 10, y: chip.minY + 10)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
