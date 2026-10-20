import AppKit

/// Hides and shows desktop icons. Stub.
@MainActor
enum DesktopIcons {
    static var isHidden = false
    static func toggle() { isHidden.toggle() }
}
