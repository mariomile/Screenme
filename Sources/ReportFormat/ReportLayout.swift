import Foundation

/// Where things are, for the app and the `screenme` tool alike: the app's defaults domain and the setting that names
/// the save folder (where Report for AI writes), and the folder captures are written to.
enum ScreenmePaths {
    /// The app's bundle identifier, which names its defaults domain.
    static let defaultsDomain = "dev.mariomiletta.Screenme"
    /// The setting that holds the save folder's path.
    static let saveFolderKey = "saveDirectory"

    /// `~/Library/Application Support/Screenme/Captures`.
    static var captures: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme/Captures", isDirectory: true)
    }

    /// The save folder as the app's settings name it, the Desktop until it is changed. Read from the app's
    /// defaults domain, so it works from the command line too.
    static var saveFolder: URL {
        if let path = UserDefaults(suiteName: defaultsDomain)?.string(forKey: saveFolderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}

/// A Report for AI folder: `Report 2026-10-21 at 10.22.33` in the save folder, holding these files. Paths are
/// relative to the folder. A folder appears under its name only once it is complete: it is written as a hidden
/// sibling and moved into place at the end.
enum ReportLayout {
    static let folderPrefix = "Report "
    static let video = "recording.mp4"
    static let summary = "summary.md"
    static let manifest = "report.json"
    static let contactSheet = "contact-sheet.png"
    static let fullContactSheet = "contact-sheet-full.png"
    static let frames = "frames"
    static let fullFrames = "frames-full"
    /// What `screenme zoom` and `frames` write.
    static let zoom = "zoom"

    /// `frame-03.png` is keyframe #3 (index 2).
    static func frameFile(_ index: Int) -> String {
        String(format: "frame-%02d.png", index + 1)
    }

    /// `frames/frame-03.png`.
    static func frame(_ index: Int) -> String {
        "\(frames)/\(frameFile(index))"
    }

    /// `frames-full/frame-03.png`: the uncropped keyframe, when the report is cropped.
    static func fullFrame(_ index: Int) -> String {
        "\(fullFrames)/\(frameFile(index))"
    }

    /// `Report 2026-10-21 at 10.22.33`.
    static func folderName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folderPrefix + formatter.string(from: date)
    }

    /// The newest report folder in `parent`, by when it was made. Nil when there is none.
    static func latest(in parent: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                                                    options: .skipsHiddenFiles)) ?? []
        let reports: [(url: URL, date: Date)] = folders.compactMap { folder in
            let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard folder.lastPathComponent.hasPrefix(folderPrefix), values?.isDirectory == true else { return nil }
            return (folder, values?.creationDate ?? .distantPast)
        }
        return reports.max { $0.date < $1.date }?.url
    }
}
