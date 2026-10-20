import AppKit
import SwiftUI

/// A short HUD message at the bottom-center of the screen under the mouse ("Text copied").
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Double = 1.6) {
        panel?.orderOut(nil)
        let view = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        let size = view.fittingSize
        let screen = NSScreen.underMouse.visibleFrame
        let frame = CGRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.78), in: Capsule())
            .padding(8)
    }
}

/// Hosts SwiftUI windows (onboarding, settings, history, editors) for a menu bar app.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()

    private var windows: [String: NSWindow] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    /// Shows the window with `id`, creating it on first use. Returns the window.
    @discardableResult
    func show<Content: View>(_ id: String, title: String, size: CGSize,
                             style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView],
                             transparentTitlebar: Bool = true,
                             @ViewBuilder content: () -> Content) -> NSWindow {
        if let window = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return window
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        if transparentTitlebar {
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
        // A menu bar app needs a regular activation policy for windows to take focus and show in Cmd-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    private func forget(_ id: String) {
        windows.removeValue(forKey: id)
        if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
