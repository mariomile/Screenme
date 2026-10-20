import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capturer {
    static func screenshot(_ target: CaptureTarget) async throws -> CGImage {
        let (filter, config) = try await target.streamSetup()
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

enum Storage {
    /// Captures live in Caches until the user saves them; drag and copy read from here.
    static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @MainActor
    static var saveDirectory: URL { AppState.shared.saveDirectory }

    static func newURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory.appendingPathComponent("Screenme \(formatter.string(from: Date())).\(ext)")
    }

    static func writePNG(_ image: CGImage) throws -> URL {
        let url = newURL(extension: "png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Copies a capture to the save folder, never overwriting an existing file.
    @MainActor @discardableResult
    static func save(_ url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        var destination = saveDirectory.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = saveDirectory.appendingPathComponent("\(base) \(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}

enum Clipboard {
    static func copyImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }

    static func copyFile(at url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }
}
