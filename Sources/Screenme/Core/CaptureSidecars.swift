import Foundation

extension Notification.Name {
    /// A capture and its sidecars went to the Trash (object: the capture's file URL). Whatever is kept in memory
    /// for that file forgets it.
    static let captureTrashed = Notification.Name("ScreenmeCaptureTrashed")
}

/// The hidden files that belong to a capture and live next to it. Hidden (a leading dot) so History, the command
/// line's capture listing and Finder never show them as captures. Save, Save As, drag out, Copy and Share use
/// the capture file and never a sidecar.
enum Sidecar: CaseIterable {
    /// A recording's events, `.<capture>.events.json` (`RecordingEvents`).
    case events
    /// The editable annotations of an image, the folder `.<capture>.screenme-edit/` (`EditSidecar`).
    case edit
    /// The cursorless source of a Smooth cursor recording, `.<capture>.screenme-source.mp4` (`BakedCursor`).
    case source

    func url(for capture: URL) -> URL {
        let folder = capture.deletingLastPathComponent()
        let name = capture.lastPathComponent
        return switch self {
        case .events: folder.appendingPathComponent(".\(name).events.json")
        case .edit: folder.appendingPathComponent(".\(name).screenme-edit", isDirectory: true)
        case .source: folder.appendingPathComponent(".\(name).screenme-source.mp4")
        }
    }

    /// Marks an edit sidecar that could not be read and was moved aside whole, `.<capture>.screenme-edit.unreadable-<date>/`
    /// (`EditSidecar`). It still belongs to the capture.
    static let unreadableMark = ".unreadable-"

    /// The sidecars `capture` has on disk, then every edit sidecar set aside as unreadable.
    static func all(for capture: URL) -> [URL] {
        let present = allCases.map { $0.url(for: capture) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let folder = capture.deletingLastPathComponent()
        let setAside = edit.url(for: capture).lastPathComponent + unreadableMark
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return present + names.filter { $0.hasPrefix(setAside) }.sorted().map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// The one way a capture leaves: the file and everything `all(for:)` finds go to the Trash, so nothing is
    /// hard-deleted, and `.captureTrashed` tells whatever remembers the file to forget it. Each goes as its own
    /// Trash item: Finder's Put Back restores only the capture, not its sidecars. Tests pass their own `moveToTrash`.
    @MainActor
    static func trash(with capture: URL, moveToTrash: (URL) throws -> Void = Sidecar.moveToTrash) {
        for url in [capture] + all(for: capture) { try? moveToTrash(url) }
        NotificationCenter.default.post(name: .captureTrashed, object: capture)
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Calls `forget` with every capture that goes to the Trash, for as long as the app runs.
    @MainActor @discardableResult
    static func onTrash(_ forget: @escaping @MainActor (URL) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .captureTrashed, object: nil, queue: .main) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { forget(url) }
        }
    }
}
