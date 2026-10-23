import Foundation

/// The folder the app writes captures to, read directly: listing captures needs no running app.
struct CaptureFolder {
    struct Capture: Equatable {
        let url: URL
        let date: Date
    }

    /// Where the app writes captures.
    static let standard = CaptureFolder(url: ScreenmePaths.captures)

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
}
