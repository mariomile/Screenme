import AppKit

/// The cards that slide in after every capture: drag one into any app, or copy, save, annotate, pin.
/// This owns the stack: where each card rests, which cards go when the screen is full, and their removal.
/// Each card (`QuickAccessCard`) animates and handles its own input.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    /// Room around the visible card for its shadow.
    static let inset: CGFloat = 24
    private let margin: CGFloat = 16
    private let gap: CGFloat = 12

    private var cards: [QuickAccessCard] = []
    private var updateObserver: NSObjectProtocol?

    private init() {
        updateObserver = NotificationCenter.default.addObserver(forName: .captureUpdated, object: nil, queue: .main) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { QuickAccess.shared.reload(url) }
        }
    }

    // MARK: Showing

    /// `file` is the capture's file being written; `preview` the picture to show until it is. The card waits for the
    /// file before any action and goes away when writing it fails.
    func show(_ item: CaptureItem, preview: CGImage? = nil, file: Task<URL, Error>) {
        // A new version of a capture already on screen replaces its card.
        for old in cards where old.model.item.url == item.url && !old.isDismissing { remove(old) }

        let screen = NSScreen.underMouse
        let card = QuickAccessCard(item: item, screen: screen, owner: self, preview: preview, file: file)
        cards.append(card)
        trimOverflow(on: screen)
        layout()
        card.slideIn()
    }

    // MARK: Layout

    /// Stacks the cards of each screen in its corner, newest at the bottom.
    private func layout() {
        let rightSide = Prefs[Pref.quickAccessPosition] == .bottomRight
        var offsets: [CGDirectDisplayID: CGFloat] = [:]
        for card in cards.reversed() where !card.isDismissing {
            let area = card.screen.visibleFrame
            let x = rightSide ? area.maxX - margin - card.size.width - Self.inset : area.minX + margin - Self.inset
            let offset = offsets[card.screen.displayID, default: 0]
            card.place(at: CGPoint(x: x, y: area.minY + margin - Self.inset + offset), edgeSign: rightSide ? 1 : -1)
            offsets[card.screen.displayID] = offset + card.size.height + gap
        }
    }

    /// Drops the oldest cards when the stack would not fit on the screen.
    private func trimOverflow(on screen: NSScreen) {
        while true {
            let stack = cards.filter { $0.screen === screen && !$0.isDismissing }
            let height = stack.reduce(margin) { $0 + $1.size.height + gap }
            guard height > screen.visibleFrame.height - margin, stack.count > 1, let oldest = stack.first else { return }
            dismiss(oldest)
        }
    }

    // MARK: Dismissing

    /// Slides the card out toward the screen edge; the others close the gap.
    func dismiss(_ card: QuickAccessCard, velocity: CGFloat = 0) {
        // A card already removed (replaced by a new version mid-drag) is off screen: animating it would start a
        // display link that never fires and never lets the card go.
        guard !card.isDismissing, cards.contains(where: { $0 === card }) else { return }
        card.slideOut(velocity: velocity)
        layout()
    }

    /// Takes the card off screen at once. Cards call this when their slide-out finished.
    func remove(_ card: QuickAccessCard) {
        card.close()
        cards.removeAll { $0 === card }
        layout()
    }

    private func reload(_ url: URL) {
        let path = url.standardizedFileURL.path
        for card in cards where card.model.item.url.standardizedFileURL.path == path {
            Task { await card.model.reload() }
        }
    }
}
