import AppKit
import SwiftUI

/// The borderless, transparent, always-on-top panel behind every Screenme overlay: Quick Access cards,
/// toasts, HUDs, recording controls, the self-timer, pins and the picker.
/// It joins every Space and full-screen app, and showing it never activates Screenme.
class FloatingPanel: NSPanel {
    private let allowsKey: Bool

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// - Parameters:
    ///   - canBeKey: the panel takes the keyboard when shown with `present(makeKey: true)` or clicked.
    ///   - activatesOnClick: a click activates Screenme (pins need it for Esc and ⌘C). Showing it still does not.
    ///   - ignoresMouse: clicks go through to whatever is below.
    init(frame: CGRect, level: NSWindow.Level, canBeKey: Bool = false, activatesOnClick: Bool = false,
         hasShadow: Bool = true, ignoresMouse: Bool = false,
         collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]) {
        allowsKey = canBeKey
        super.init(contentRect: frame, styleMask: activatesOnClick ? [.borderless] : [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        self.hasShadow = hasShadow
        // Only ever set to true: an explicit false makes transparent areas catch clicks too.
        if ignoresMouse { ignoresMouseEvents = true }
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        self.collectionBehavior = collectionBehavior
    }

    /// Fades the panel in. `start` is a frame to grow or slide from; Reduce Motion skips it.
    func present(makeKey: Bool = false, from start: CGRect? = nil) {
        let final = frame
        let moves = start != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if moves, let start { setFrame(start, display: false) }
        alphaValue = 0
        orderFrontRegardless()
        if makeKey { self.makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            if moves { animator().setFrame(final, display: true) }
        } completionHandler: {
            MainActor.assumeIsolated { if self.hasShadow { self.invalidateShadow() } }
        }
    }

    /// Fades the panel out and removes it, then runs `completion`.
    func dismiss(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                completion?()
            }
        }
    }
}

/// A blurred background behind SwiftUI content: dark HUD material for overlays by default.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = state
    }
}
