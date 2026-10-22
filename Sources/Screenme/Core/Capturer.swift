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
        let url = newURL(extension: Prefs[Pref.imageFormat].fileExtension)
        try write(image, to: url)
        return url
    }

    /// Encodes `image` into `url` in the format its extension names. Safe off the main thread.
    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = encoded(image, as: ImageFormat(of: url)) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    /// `image` as a file of `format`, JPEG at the user's quality. Safe off the main thread.
    static func encoded(_ image: CGImage, as format: ImageFormat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        let options = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: Prefs[Pref.jpegQuality]] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Copies a capture to the save folder, never overwriting an existing file.
    @discardableResult
    static func save(_ url: URL) throws -> URL {
        let folder = saveDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The names never run out, so there is always a first free one.
        let destination = saveNames(for: url).lazy.map { folder.appendingPathComponent($0) }
            .first { !FileManager.default.fileExists(atPath: $0.path) }!
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// The copy of `url` that `save` already put in the save folder, if its bytes still match the capture.
    /// Looks where `save` would have written it, up to the first free name.
    static func savedCopy(of url: URL) -> URL? {
        let folder = saveDirectory
        for name in saveNames(for: url) {
            let candidate = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            if FileManager.default.contentsEqual(atPath: candidate.path, andPath: url.path) { return candidate }
        }
        return nil
    }

    /// The names `save` tries for a copy of `url`, in order: "name.ext", then "name 2.ext", "name 3.ext" and so on.
    private static func saveNames(for url: URL) -> some Sequence<String> {
        let base = url.deletingPathExtension().lastPathComponent
        return (1...).lazy.map { $0 == 1 ? url.lastPathComponent : "\(base) \($0).\(url.pathExtension)" }
    }

    /// Asks where to save a copy of `url`, replacing a file the user chose to overwrite.
    /// Returns nil when cancelled.
    @MainActor
    static func saveAs(_ url: URL, suggestedName: String) async throws -> URL? {
        guard let destination = await chooseDestination(suggestedName: suggestedName) else { return nil }
        try copy(url, to: destination)
        return destination
    }

    /// The save panel alone, for a file that does not exist yet (an export still to run). Returns nil when cancelled.
    /// The panel needs Screenme active; focus goes back afterwards.
    @MainActor
    static func chooseDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = saveDirectory
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (suggestedName as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        let previous = FocusKeeper.frontmostExternal()
        FocusKeeper.activateSelf()
        let response = panel.runModal()
        await FocusKeeper.restore(previous)
        return response == .OK ? panel.url : nil
    }

    /// Copies `url` to `destination`, replacing a file the user chose to overwrite.
    static func copy(_ url: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: url, to: destination)
    }
}

enum Clipboard {
    /// One pasteboard item holding the image data and the file: two items make some apps paste twice or paste a file icon.
    static func copyImage(at url: URL, to board: NSPasteboard = .general) {
        guard let data = try? Data(contentsOf: url) else { return }
        board.clearContents()
        let entry = NSPasteboardItem()
        entry.setData(data, forType: NSPasteboard.PasteboardType(ImageFormat(of: url).type.identifier))
        entry.setString(url.absoluteString, forType: .fileURL)
        board.writeObjects([entry])
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
