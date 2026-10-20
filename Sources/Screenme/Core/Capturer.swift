import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capturer {
    /// A still image of `target`, honoring the screenshot preferences (cursor, shadow, retina).
    static func screenshot(_ target: CaptureTarget) async throws -> CGImage {
        let (filter, config) = try await target.streamSetup(showsCursor: Prefs[Pref.showCursorInShots],
                                                            retina: Prefs[Pref.retinaResolution])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

enum Storage {
    /// Captures live in Application Support (not Caches, which macOS may purge) so history keeps working.
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var saveDirectory: URL { URL(fileURLWithPath: Prefs[Pref.saveDirectory]) }

    static func newURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let prefix = Prefs[Pref.fileNamePrefix].isEmpty ? "Screenme" : Prefs[Pref.fileNamePrefix]
        var url = directory.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(prefix) \(formatter.string(from: Date())) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Writes in the user's chosen format (PNG or JPEG).
    static func write(_ image: CGImage) throws -> URL {
        let format = Prefs[Pref.imageFormat]
        let url = newURL(extension: format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: Prefs[Pref.jpegQuality]] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Copies a capture to the save folder, never overwriting an existing file.
    @discardableResult
    static func save(_ url: URL) throws -> URL {
        let folder = saveDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(n).\(url.pathExtension)")
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
        board.setData(data, forType: NSPasteboard.PasteboardType(ImageFormat(of: url).type.identifier))
        board.writeObjects([url as NSURL])
    }

    static func copyFile(at url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    static func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func copy(_ item: CaptureItem) {
        switch item.kind {
        case .image: copyImage(at: item.url)
        case .video: copyFile(at: item.url)
        case .gif: copyGIF(at: item.url)
        }
    }

    /// The file plus its GIF data, so apps that paste files keep it and chat apps animate it.
    private static func copyGIF(at url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url) {
            entry.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        board.writeObjects([entry])
    }
}

enum Sounds {
    static func shutter() {
        guard Prefs[Pref.playSounds] else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }
}
