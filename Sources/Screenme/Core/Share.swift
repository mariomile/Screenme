import AppKit

/// The macOS share menu (AirDrop, Messages, Mail…) for a capture file.
/// With "Hide sensitive info when sharing" it shares a redacted temporary copy of an image instead.
@MainActor
enum Share {
    /// Opens the share menu at the click that triggered it, e.g. from a SwiftUI button.
    static func show(_ url: URL) {
        guard let (view, point) = anchor() else { return }
        guard Prefs[Pref.hideSensitiveWhenSharing] else { return present([url], in: view, at: point) }
        Task {
            do {
                if let copy = try await Redaction.redactedCopy(of: url) {
                    Toast.show("Sharing a copy, \(CaptureAction.hiddenItems(copy.count)) hidden", symbol: "eye.slash.fill")
                    present([copy.url], in: view, at: point)
                } else {
                    present([url], in: view, at: point)
                }
            } catch {
                Feedback.failure("Could not read the text")
            }
        }
    }

    private static func present(_ items: [URL], in view: NSView, at point: CGPoint) {
        NSSharingServicePicker(items: items)
            .show(relativeTo: CGRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// Where the menu opens: the pointer, in the window under it. A click and a chosen menu item both leave it there.
    private static func anchor() -> (NSView, CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.contains(mouse) }), let view = window.contentView else { return nil }
        return (view, view.convert(window.convertPoint(fromScreen: mouse), from: nil))
    }
}
