import AppKit

/// The macOS share menu (AirDrop, Messages, Mail…) for a capture file.
@MainActor
enum Share {
    /// Opens the share menu at the click that triggered it, e.g. from a SwiftUI button.
    static func show(_ url: URL) {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        NSSharingServicePicker(items: [url])
            .show(relativeTo: CGRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// A "Share" item with the services as a submenu, for AppKit context menus.
    static func menuItem(for url: URL) -> NSMenuItem {
        NSSharingServicePicker(items: [url]).standardShareMenuItem
    }
}
