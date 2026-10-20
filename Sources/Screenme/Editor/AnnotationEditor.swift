import AppKit

/// The annotation editor. Stub: opens the image in Preview.
@MainActor
enum AnnotationEditor {
    static func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(item.url)
    }
}
