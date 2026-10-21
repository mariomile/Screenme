import AppKit

/// The folder the app writes captures to. Reads it, and asks the app for new captures through `screenme://` links:
/// the app holds the Screen Recording permission, this tool only triggers it and waits for the file.
struct CaptureFolder {
    struct Capture: Equatable {
        let url: URL
        let date: Date
    }

    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case notLaunchable(String)
        case timedOut(seconds: Int)

        var description: String {
            switch self {
            case .notInstalled:
                return "Screenme is not installed: no app opens screenme:// links. Run scripts/install.sh in the Screenme checkout."
            case .notLaunchable(let reason):
                return "Could not open Screenme: \(reason)"
            case .timedOut(let seconds):
                return "No new capture appeared within \(seconds) s. Check that Screenme is allowed to record the screen "
                    + "(System Settings > Privacy & Security), that no other capture is in progress, and that the window or area exists."
            }
        }
    }

    /// `~/Library/Application Support/Screenme/Captures`, as `Storage.directory` in the app.
    static let standard = CaptureFolder(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenme/Captures", isDirectory: true))

    let url: URL

    /// Every capture, newest first. Hidden files (.DS_Store) are not captures.
    func captures() -> [Capture] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        return files.compactMap { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return Capture(url: file, date: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    var latest: Capture? { captures().first }

    /// File names in the folder now, to tell new captures apart later.
    func names() -> Set<String> {
        Set(captures().map(\.url.lastPathComponent))
    }

    /// The newest PNG or JPEG (the formats captures are saved in) that is not in `existing` and is fully written.
    /// The app writes images in place, so a file that has just appeared may still be half a PNG.
    func newImage(notIn existing: Set<String>) -> URL? {
        captures().first { !existing.contains($0.url.lastPathComponent) && Self.isComplete($0.url) }?.url
    }

    /// Whether the file ends the way a finished PNG (the IEND chunk) or JPEG (the end-of-image marker) ends.
    /// ImageIO is no help here: it reports a cut-off PNG as complete.
    static func isComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 8 else { return false }
        try? handle.seek(toOffset: size - 8)
        let tail = [UInt8]((try? handle.readToEnd()) ?? Data())
        switch url.pathExtension.lowercased() {
        case "png": return tail == [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        case "jpg", "jpeg": return tail.suffix(2) == [0xFF, 0xD9]
        default: return false
        }
    }

    /// Opens the link in Screenme without bringing it forward, then waits for the new image and returns it.
    func take(_ request: CaptureRequest, timeout: Int = 20) async throws -> URL {
        let existing = names()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.open([request.link], withApplicationAt: try Self.appURL(), configuration: configuration)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.notLaunchable(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if let url = newImage(notIn: existing) { return url }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Failure.timedOut(seconds: timeout)
    }

    /// The Screenme.app this tool is embedded in (the `screenme` on PATH is a symlink into it), otherwise the app
    /// macOS opens `screenme://` links with.
    private static func appURL() throws -> URL {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let bundle = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let bundle, bundle.pathExtension == "app" { return bundle }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: CaptureRequest.fullscreen.link) else { throw Failure.notInstalled }
        return app
    }
}
