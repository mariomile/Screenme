import Foundation

/// Files Screenme writes for other apps to read: the editor's Share file, the file Copy for AI names in the pasted
/// text, and redacted copies for sharing. One flat folder in the temporary directory, one file per name (sharing the
/// same capture again overwrites its copy), swept once at launch. A copy stays at least a day: Copy for AI's text is
/// pasted later and names the file.
enum TemporaryCopies {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeCopies", isDirectory: true)

    /// `data` in the folder as `name`. Nil when it could not be written.
    static func write(_ data: Data, named name: String, in folder: URL = folder) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Removes the copies not written for `age`. Run once at launch.
    static func removeStale(olderThan age: TimeInterval = 24 * 3600, in folder: URL = folder) {
        let cutoff = Date().addingTimeInterval(-age)
        let copies = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for copy in copies {
            let modified = (try? copy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: copy) }
        }
    }
}
