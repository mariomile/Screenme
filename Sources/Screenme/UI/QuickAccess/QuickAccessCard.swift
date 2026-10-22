import AppKit
import QuartzCore
import SwiftUI

/// One Quick Access card: a non-activating panel, so it never takes focus from the app the user is in.
/// It springs to where `QuickAccess` places it on a display-synced link, follows swipes, closes itself
/// after the auto-close delay, and runs the capture actions its views ask for.
@MainActor
final class QuickAccessCard: NSObject {
    let model: CardModel
    let panel: FloatingPanel
    let size: CGSize
    let screen: NSScreen
    private unowned let owner: QuickAccess

    /// Where the card settles in the stack.
    private(set) var rest: CGPoint = .zero
    /// -1 when the card sits at the left edge, 1 at the right edge.
    private(set) var edgeSign: CGFloat = -1
    private(set) var isDismissing = false
    /// True while a swipe owns the position.
    private var isHeld = false

    // Spring state: panel origin, velocity and the point it moves to.
    private var origin: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var target: CGPoint = .zero
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private var autoClose: DispatchWorkItem?

    /// `preview`: the picture of `file` while it is still being written (see `QuickAccess.show(_:preview:file:)`).
    init(item: CaptureItem, screen: NSScreen, owner: QuickAccess, preview: CGImage?, file: Task<URL, Error>) {
        self.screen = screen
        self.owner = owner
        let width = Prefs[Pref.quickAccessSize].cardWidth
        let aspect = preview.map { CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? Thumbnails.aspectRatio(of: item)
        // Between 140 and 220 points tall at the medium width, in proportion for the other sizes.
        let height = CGFloat.minimum(width * 220 / 224, CGFloat.maximum(width * 140 / 224, width * aspect))
        size = CGSize(width: width, height: height)
        model = CardModel(item: item, preview: preview, file: file)

        let inset = QuickAccess.inset
        let frame = CGRect(x: 0, y: 0, width: width + inset * 2, height: height + inset * 2)
        panel = FloatingPanel(frame: frame, level: .statusBar, hasShadow: false,
                              collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        super.init()

        let root = CardRootView(frame: frame)
        root.card = self
        let hosting = FirstMouseHostingView(rootView: QuickAccessCardView(model: model, size: size, card: self))
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)
        panel.contentView = root
        // The thumbnail of the written file, with its watermark and notch cover, replaces the preview.
        whenWritten { [model] in await model.reload() }
    }

    // MARK: Placement

    /// Sets where the card rests. It springs there unless a swipe holds it.
    func place(at rest: CGPoint, edgeSign: CGFloat) {
        self.rest = rest
        self.edgeSign = edgeSign
        guard !isHeld else { return }
        move(to: rest)
    }

    /// Shows the card just past the screen edge and springs it in.
    func slideIn() {
        origin = CGPoint(x: rest.x + edgeSign * size.width * 0.9, y: rest.y)
        panel.alphaValue = 0
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        move(to: rest)
        scheduleAutoClose()
    }

    /// Springs the card out past the screen edge; it removes itself once faded.
    func slideOut(velocity: CGFloat) {
        isDismissing = true
        isHeld = false
        cancelAutoClose()
        self.velocity = CGPoint(x: velocity, y: 0)
        move(to: CGPoint(x: rest.x + edgeSign * size.width * 1.2, y: origin.y))
    }

    /// Takes the card off screen now.
    func close() {
        cancelAutoClose()
        stopMotion()
        panel.orderOut(nil)
    }

    // MARK: Actions from the views

    /// Runs `action` on the capture. The card goes away once it did something, except Show in Finder,
    /// and Share, whose menu opens from the card.
    func perform(_ action: CaptureAction) {
        whenWritten { [self] in
            guard await action.perform(model.item), action != .reveal, action != .share else { return }
            owner.dismiss(self)
        }
    }

    /// Runs `work` once the capture's file is written. When writing failed it never runs: the card goes, with a toast.
    private func whenWritten(_ work: @escaping @MainActor () async -> Void) {
        Task {
            guard let error = await model.whenWritten(work) else { return }
            Feedback.failure(error.localizedDescription, duration: 3.2)
            owner.dismiss(self)
        }
    }

    func dismiss() {
        owner.dismiss(self)
    }

    func hoverChanged(_ hovering: Bool) {
        model.hovering = hovering
        if hovering { cancelAutoClose() } else { scheduleAutoClose() }
    }

    /// A swipe in progress, `dx` points from where it started. Toward the edge follows the finger, away from it resists.
    func swipeChanged(_ dx: CGFloat) {
        isHeld = true
        cancelAutoClose()
        stopMotion()
        let toward = dx * edgeSign
        let shown = toward > 0 ? toward : toward * 0.2
        origin.x = rest.x + shown * edgeSign
        velocity = .zero
        panel.setFrameOrigin(origin)
        updateAlpha()
    }

    /// A far or fast swipe toward the edge dismisses; anything else springs back.
    func swipeEnded(_ dx: CGFloat, velocityX: CGFloat) {
        if dx * edgeSign > 70 || velocityX * edgeSign > 700 {
            owner.dismiss(self, velocity: velocityX)
        } else {
            isHeld = false
            velocity = CGPoint(x: velocityX, y: 0)
            move(to: rest)
            scheduleAutoClose()
        }
    }

    func dragStarted() {
        model.dragging = true
        cancelAutoClose()
    }

    func dragEnded(dropped: Bool) {
        model.dragging = false
        if dropped && Prefs[Pref.quickAccessCloseAfterDrag] {
            owner.dismiss(self)
        } else {
            scheduleAutoClose()
        }
    }

    // MARK: Spring

    private func move(to point: CGPoint) {
        target = point
        guard link == nil, let view = panel.contentView else { return }
        lastTick = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopMotion() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30.0))
        lastTick = now
        step(dt)
        if isDismissing && panel.alphaValue < 0.02 {
            owner.remove(self)
        } else if origin == target && velocity == .zero {
            stopMotion()
        }
    }

    private func step(_ dt: CGFloat) {
        let stiffness: CGFloat = 280
        let damping: CGFloat = isDismissing ? 34 : 25
        for axis in 0..<2 {
            let position = axis == 0 ? origin.x : origin.y
            let goal = axis == 0 ? target.x : target.y
            var v = axis == 0 ? velocity.x : velocity.y
            let acceleration = stiffness * (goal - position) - damping * v
            v += acceleration * dt
            var next = position + v * dt
            if abs(goal - next) < 0.3 && abs(v) < 8 {
                next = goal
                v = 0
            }
            if axis == 0 { origin.x = next; velocity.x = v } else { origin.y = next; velocity.y = v }
        }
        panel.setFrameOrigin(origin)
        updateAlpha()
    }

    private func updateAlpha() {
        let travel = abs(origin.x - rest.x) / (size.width * 0.9)
        panel.alphaValue = max(0, min(1, 1 - travel))
    }

    // MARK: Auto close

    private func scheduleAutoClose() {
        cancelAutoClose()
        let seconds = Prefs[Pref.quickAccessAutoClose]
        guard seconds > 0, !model.hovering, !model.dragging, !isDismissing else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.hovering, !self.model.dragging else { return }
                self.whenWritten {
                    // Not a second copy of a capture already saved after capture.
                    if Prefs[Pref.quickAccessAutoCloseSaves] {
                        let url = self.model.item.url
                        _ = Storage.savedCopy(of: url) ?? (try? Storage.save(url))
                    }
                    self.owner.dismiss(self)
                }
            }
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func cancelAutoClose() {
        autoClose?.cancel()
        autoClose = nil
    }
}
