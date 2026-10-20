import AppKit

/// Recent captures, newest first. Thumbnails refresh on `ScreenmeCaptureUpdated` (object: the file URL).
/// The index is a small JSON file in Application Support;
/// the captures themselves stay in `Storage.directory`.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()

    @Published private(set) var items: [CaptureItem] = []
    /// Bumped when a file changes on disk, so thumbnails of that file regenerate.
    @Published private(set) var revisions: [URL: Int] = [:]

    private struct Entry: Codable {
        var id: UUID
        var path: String
        var kind: CaptureItem.Kind
        var date: Date
    }

    private let indexURL: URL
    private let writer = DispatchQueue(label: "dev.mariomiletta.Screenme.history", qos: .utility)

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("history.json")
        items = Self.load(from: indexURL)

        NotificationCenter.default.addObserver(forName: Notification.Name("ScreenmeCaptureUpdated"), object: nil, queue: .main) { [weak self] note in
            let url = note.object as? URL
            MainActor.assumeIsolated { self?.fileChanged(url) }
        }
    }

    // MARK: Changes

    /// Inserts a capture at the top. A capture already in the index (same file) moves to the top.
    func add(_ item: CaptureItem) {
        items.removeAll { $0.id == item.id || $0.url == item.url }
        items.insert(item, at: 0)
        save()
    }

    /// Removes the entry only; the file stays where it is.
    func remove(_ item: CaptureItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Moves the file to the Trash and removes the entry.
    func trash(_ item: CaptureItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        remove(item)
    }

    /// Drops entries older than `Pref.historyDays` (0 keeps everything) and entries whose file is gone.
    func prune() {
        let days = Prefs[Pref.historyDays]
        let cutoff = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
        let kept = items.filter { item in
            if let cutoff, item.date < cutoff { return false }
            return FileManager.default.fileExists(atPath: item.url.path)
        }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    func revision(of url: URL) -> Int { revisions[url] ?? 0 }

    private func fileChanged(_ url: URL?) {
        guard let url else { return }
        HistoryThumbnails.invalidate(url)
        revisions[url, default: 0] += 1
    }

    // MARK: Persistence

    private func save() {
        let entries = items.map { Entry(id: $0.id, path: $0.url.path, kind: $0.kind, date: $0.date) }
        let url = indexURL
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func load(from url: URL) -> [CaptureItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return [] }
        return entries.map { CaptureItem(url: URL(fileURLWithPath: $0.path), kind: $0.kind, id: $0.id, date: $0.date) }
    }
}
