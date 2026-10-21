import AppKit

/// Recent captures, newest first. Thumbnails refresh on `.captureUpdated`.
/// The index is a small JSON file in Application Support;
/// the captures themselves stay in `Storage.directory`.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()

    @Published private(set) var items: [CaptureItem] = []
    /// Bumped when a file changes on disk, so thumbnails of that file regenerate.
    @Published private(set) var revisions: [URL: Int] = [:]

    /// The text Vision read in each image capture, by file. Absent until read; empty when the image has none.
    /// Kept apart from `items` so the shared `CaptureItem` stays small; saved in the index with each entry.
    @Published private(set) var recognizedText: [URL: String] = [:]

    struct Entry: Codable, Equatable {
        var id: UUID
        var path: String
        var kind: CaptureItem.Kind
        var date: Date
        /// Text in the image, for History search. Nil until recognized (indexes written before this field decode as nil).
        var text: String?
    }

    private let indexURL: URL
    /// Screenme's own captures folder: expired captures in it go to the Trash. Files anywhere else are never touched.
    private let capturesDirectory: URL
    private let writer = DispatchQueue(label: "dev.mariomiletta.Screenme.history", qos: .utility)
    /// Reads the text of an image file. Tests replace it.
    var textReader: @Sendable (URL) async -> String = CaptureHistory.recognizeFile
    private var reading = Set<URL>()
    private var backlogTask: Task<Void, Never>?

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.init(indexURL: support.appendingPathComponent("history.json"), capturesDirectory: Storage.directory)
        startBacklog()
    }

    /// Tests pass their own index file and captures folder.
    init(indexURL: URL, capturesDirectory: URL) {
        self.indexURL = indexURL
        self.capturesDirectory = capturesDirectory.standardizedFileURL
        let loaded = Self.load(from: indexURL)
        items = loaded.items
        recognizedText = loaded.texts

        NotificationCenter.default.addObserver(forName: .captureUpdated, object: nil, queue: .main) { [weak self] note in
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
        readText(of: item)
    }

    /// The newest image capture older than `item`, for "Compare with Previous".
    func previousImage(before item: CaptureItem) -> CaptureItem? {
        items.first { $0.kind == .image && $0.id != item.id && $0.date < item.date }
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
    /// An expired capture in Screenme's own captures folder goes to the Trash with its entry;
    /// a file anywhere else (the user's save folder) stays where it is.
    func prune(now: Date = Date()) {
        let days = Prefs[Pref.historyDays]
        let cutoff = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: now) : nil
        var kept: [CaptureItem] = []
        for item in items {
            if let cutoff, item.date < cutoff {
                if isOwnCapture(item.url) { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
                continue
            }
            if FileManager.default.fileExists(atPath: item.url.path) { kept.append(item) }
        }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    private func isOwnCapture(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == capturesDirectory.path
    }

    func revision(of url: URL) -> Int { revisions[url] ?? 0 }

    private func fileChanged(_ url: URL?) {
        guard let url else { return }
        revisions[url, default: 0] += 1
        // The image changed (the editor saved over it): what it says may have too.
        guard let item = items.first(where: { $0.url == url }) else { return }
        recognizedText[url] = nil
        readText(of: item)
    }

    // MARK: Persistence

    private func save() {
        let entries = items.map { Entry(id: $0.id, path: $0.url.path, kind: $0.kind, date: $0.date, text: recognizedText[$0.url]) }
        let url = indexURL
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func load(from url: URL) -> (items: [CaptureItem], texts: [URL: String]) {
        guard let data = try? Data(contentsOf: url) else { return ([], [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return ([], [:]) }
        var texts: [URL: String] = [:]
        let items = entries.map { entry in
            let url = URL(fileURLWithPath: entry.path)
            // Entries written before GIFs had their own kind stored them as images.
            let kind: CaptureItem.Kind = url.pathExtension.lowercased() == "gif" ? .gif : entry.kind
            if let text = entry.text { texts[url] = text }
            return CaptureItem(url: url, kind: kind, id: entry.id, date: entry.date)
        }
        return (items, texts)
    }

    // MARK: Text in images

    /// Reads the text of an image capture in the background and stores it. Never blocks the UI.
    private func readText(of item: CaptureItem) {
        guard item.kind == .image, reading.insert(item.url).inserted else { return }
        let reader = textReader
        Task { [weak self] in
            let text = await reader(item.url)
            guard let self else { return }
            reading.remove(item.url)
            // Dropped from History while reading: nothing to store.
            guard items.contains(where: { $0.url == item.url }) else { return }
            recognizedText[item.url] = text
            save()
        }
    }

    /// Images from before text search existed (or whose read was cut short) get read a few at a time, at background priority.
    /// Pauses while a recording runs.
    func startBacklog(batch: Int = 3, pause: Duration = .seconds(4)) {
        guard backlogTask == nil else { return }
        backlogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8)) // Let launch settle.
            while !Task.isCancelled {
                guard let self else { return }
                if RecordingController.shared.isRecording {
                    try? await Task.sleep(for: pause)
                    continue
                }
                let pending = items.filter { $0.kind == .image && recognizedText[$0.url] == nil && !reading.contains($0.url) }
                if pending.isEmpty { backlogTask = nil; return }
                for item in pending.prefix(batch) {
                    let text = await textReader(item.url)
                    guard items.contains(where: { $0.url == item.url }) else { continue }
                    recognizedText[item.url] = text
                }
                save()
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// Vision on the file at background priority. Empty when the image cannot be read or has no text.
    @Sendable static func recognizeFile(_ url: URL) async -> String {
        guard let image = await Task.detached(priority: .background, operation: { Thumbnails.decodeImage(at: url, maxPixelSize: nil) }).value else { return "" }
        return (try? await TextRecognizer.recognize(image, priority: .background)) ?? ""
    }
}
