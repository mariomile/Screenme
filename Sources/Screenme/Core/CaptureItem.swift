import Foundation

/// One finished capture: a file in `Storage.directory`.
struct CaptureItem: Identifiable, Hashable {
    /// GIFs come from recordings: they follow the recording preferences and sit under Recordings in History.
    enum Kind: String, Codable { case image, video, gif }

    let id: UUID
    var url: URL
    let kind: Kind
    let date: Date

    init(url: URL, kind: Kind, id: UUID = UUID(), date: Date = Date()) {
        self.id = id
        self.url = url
        self.kind = kind
        self.date = date
    }
}
