import AppKit

/// The All-in-One capture bar. Stub: goes straight to area capture.
@MainActor
enum AllInOneHUD {
    static func show(perform: @escaping (ShortcutAction) -> Void) {
        perform(.captureArea)
    }
}
