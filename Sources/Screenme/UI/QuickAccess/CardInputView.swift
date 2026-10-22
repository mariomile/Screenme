import AppKit
import SwiftUI

/// The card panel's root view. Reports mouse enter and exit even though the panel is never key.
final class CardRootView: NSView {
    weak var card: QuickAccessCard?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { card?.hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { card?.hoverChanged(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the card's SwiftUI face; the first click works without activating Screenme.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Puts `CardInputView` under the card's hover controls.
struct CardInputSurface: NSViewRepresentable {
    let model: CardModel
    weak var card: QuickAccessCard?

    func makeNSView(context: Context) -> CardInputView { CardInputView(model: model, card: card) }

    func updateNSView(_ view: CardInputView, context: Context) {
        view.model = model
        view.card = card
    }
}

/// Double-click to edit, the right-click menu, swipe to dismiss (mouse or trackpad) and the file drag.
/// It decides what a gesture is; the card does what it means.
final class CardInputView: NSView, NSDraggingSource {
    var model: CardModel
    weak var card: QuickAccessCard?

    private var downLocation: CGPoint = .zero
    private enum Mode { case undecided, swiping, dragging }
    private var mode: Mode = .undecided
    private var lastSample: (x: CGFloat, time: TimeInterval) = (0, 0)
    private var velocityX: CGFloat = 0
    private var scrollOffset: CGFloat = 0

    init(model: CardModel, card: QuickAccessCard?) {
        self.model = model
        self.card = card
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        mode = .undecided
        velocityX = 0
        lastSample = (downLocation.x, event.timestamp)
        if event.clickCount == 2 { card?.perform(.edit) }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        let dx = location.x - downLocation.x
        let dy = location.y - downLocation.y

        if mode == .undecided {
            guard hypot(dx, dy) >= 4 else { return }
            let sign = card?.edgeSign ?? -1
            // A mostly horizontal move toward the screen edge swipes the card away. Anything else drags the file out,
            // as soon as the file is written.
            let swipe = abs(dx) > abs(dy) * 1.2 && dx * sign > 0
            guard swipe || model.canDrag else { return }
            mode = swipe ? .swiping : .dragging
            if mode == .dragging { beginFileDrag(with: event) }
        }

        if mode == .swiping {
            let dt = event.timestamp - lastSample.time
            if dt > 0.001 { velocityX = (location.x - lastSample.x) / CGFloat(dt) }
            lastSample = (location.x, event.timestamp)
            card?.swipeChanged(dx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .swiping {
            card?.swipeEnded(NSEvent.mouseLocation.x - downLocation.x, velocityX: velocityX)
        }
        mode = .undecided
    }

    // MARK: Trackpad swipe

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || scrollOffset != 0 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began, .changed:
            scrollOffset += delta
            card?.swipeChanged(scrollOffset)
        case .ended, .cancelled:
            let total = scrollOffset
            scrollOffset = 0
            card?.swipeEnded(total, velocityX: 0)
        default:
            break
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let kind = model.item.kind
        let menu = NSMenu()
        for action in CaptureAction.allCases where action.isAvailable(for: kind) {
            if action == .edit || action == .trash { menu.addItem(.separator()) }
            // The share menu lists the services as a submenu.
            if action == .share {
                menu.addItem(Share.menuItem(for: model.item.url))
                continue
            }
            let item = NSMenuItem(title: action.title(for: kind), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CaptureAction.allCases.firstIndex(of: action)
            item.image = NSImage(systemSymbolName: action.symbol(for: kind), accessibilityDescription: nil)
            item.toolTip = action.help(for: kind)
            menu.addItem(item)
        }
        if kind == .image, CaptureHistory.shared.previousImage(before: model.item) != nil {
            let compare = NSMenuItem(title: "Compare with Previous", action: #selector(compareWithPrevious), keyEquivalent: "")
            compare.target = self
            compare.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            compare.toolTip = "Puts the previous screenshot (Before) and this one (After) in one image and opens it in the editor. Good for a fix, a bug report or feedback."
            // Before the separator that sets Trash apart.
            menu.insertItem(compare, at: menu.items.count - 2)
        }
        return menu
    }

    @objc private func compareWithPrevious() {
        guard let before = CaptureHistory.shared.previousImage(before: model.item) else { return }
        ImageCombiner.beforeAfterAndEdit(before: before, after: model.item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        card?.perform(CaptureAction.allCases[index])
    }

    // MARK: File drag

    private func beginFileDrag(with event: NSEvent) {
        let url = model.item.url
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = model.thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
        let maxSide: CGFloat = 150
        let aspect = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
        let dragSize = aspect >= 1 ? CGSize(width: maxSide, height: maxSide / aspect) : CGSize(width: maxSide * aspect, height: maxSide)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - dragSize.width / 2, y: point.y - dragSize.height / 2,
                                     width: dragSize.width, height: dragSize.height), contents: image)
        card?.dragStarted()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        card?.dragEnded(dropped: !operation.isEmpty)
    }
}
