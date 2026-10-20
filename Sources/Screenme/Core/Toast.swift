import AppKit
import SwiftUI

/// A short HUD message at the bottom-center of the screen under the mouse ("Text copied"),
/// or a progress bar for longer work ("Creating GIF").
@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Double = 1.6) {
        panel?.orderOut(nil)
        let panel = makePanel(ToastView(text: text, symbol: symbol))
        panel.present()
        self.panel = panel
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            panel.dismiss()
        }
    }

    /// Shows a progress bar until `finish()` is called on the handle.
    static func progress(_ title: String) -> ToastHandle {
        let model = ToastProgress(title: title)
        let panel = makePanel(ProgressToastView(model: model))
        panel.present()
        return ToastHandle(model: model, panel: panel)
    }

    private static func makePanel<Content: View>(_ content: Content) -> FloatingPanel {
        let view = NSHostingView(rootView: content)
        let size = view.fittingSize
        let screen = NSScreen.underMouse.visibleFrame
        let frame = CGRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height)
        let panel = FloatingPanel(frame: frame, level: .statusBar, ignoresMouse: true)
        panel.contentView = view
        return panel
    }
}

/// A progress toast on screen.
@MainActor
final class ToastHandle {
    private let model: ToastProgress
    private var panel: FloatingPanel?

    fileprivate init(model: ToastProgress, panel: FloatingPanel) {
        self.model = model
        self.panel = panel
    }

    /// `progress` runs from 0 to 1.
    func update(_ progress: Double, title: String? = nil) {
        model.progress = min(max(progress, 0), 1)
        if let title { model.title = title }
    }

    func finish() {
        panel?.dismiss()
        panel = nil
    }
}

@MainActor
private final class ToastProgress: ObservableObject {
    @Published var title: String
    @Published var progress: Double = 0
    init(title: String) { self.title = title }
}

private struct ProgressToastView: View {
    @ObservedObject var model: ToastProgress

    var body: some View {
        VStack(spacing: 8) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 180)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .padding(8)
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
            FocusKeeper.activateSelf()
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
        FocusKeeper.activateSelf()
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
