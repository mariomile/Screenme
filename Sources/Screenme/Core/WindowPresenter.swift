import AppKit
import SwiftUI

/// Hosts SwiftUI windows (onboarding, settings, history, editors) for a menu bar app.
/// While any is open Screenme is a regular app, so its windows take focus and show in Cmd-Tab.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()

    private var windows: [String: NSWindow] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    /// Shows the window with `id`, creating it on first use. Returns the window.
    /// A style with `.fullSizeContentView` gets a transparent titlebar with the title hidden.
    @discardableResult
    func show<Content: View>(_ id: String, title: String, size: CGSize,
                             style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView],
                             @ViewBuilder content: () -> Content) -> NSWindow {
        if let window = windows[id] {
            bringToFront(window)
            return window
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        if style.contains(.fullSizeContentView) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        windows[id] = window
        observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { WindowPresenter.shared.forget(id) }
        }
        NSApp.setActivationPolicy(.regular)
        bringToFront(window)
        return window
    }

    /// Brings the window with `id` to the front. Returns false when it is not open.
    @discardableResult
    func focus(_ id: String) -> Bool {
        guard let window = windows[id] else { return false }
        bringToFront(window)
        return true
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func bringToFront(_ window: NSWindow) {
        FocusKeeper.activateSelf()
        window.makeKeyAndOrderFront(nil)
    }

    private func forget(_ id: String) {
        windows.removeValue(forKey: id)
        if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
