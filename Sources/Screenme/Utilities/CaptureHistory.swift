import AppKit

/// Recent captures, persisted. Stub.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()
    @Published private(set) var items: [CaptureItem] = []

    func add(_ item: CaptureItem) { items.insert(item, at: 0) }
    func prune() {}
}

/// The history browser window. Stub.
@MainActor
enum HistoryWindow {
    static func show() {}
}
