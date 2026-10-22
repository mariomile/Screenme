import AppKit
import SwiftUI

/// The All-in-One bar: every way to capture in one floating strip near the bottom of the screen.
@MainActor
enum AllInOneHUD {
    private static var controller: HUDController?

    static var isOpen: Bool { controller != nil }

    /// What `perform` gets: the chosen action, the link's target when a link chose it, and whether it is an Area
    /// capture picked with the Repeat toggle on.
    typealias Perform = (_ action: ShortcutAction, _ target: ActionLink.Target?, _ repeating: Bool) -> Void

    /// Shows the bar. Showing it again while it is open closes it, so the shortcut toggles.
    static func show(perform: @escaping Perform) {
        if let controller {
            controller.dismiss()
            return
        }
        let controller = HUDController(perform: perform) { Self.controller = nil }
        Self.controller = controller
        controller.present()
    }

    /// Closes the bar and runs `action` as if it had been picked from the bar, e.g. when its shortcut is pressed.
    /// `target` comes from a `screenme://` link and is passed on to `perform`.
    static func choose(_ action: ShortcutAction, target: ActionLink.Target?) {
        controller?.choose(action, target: target)
    }
}

// MARK: - Model

private struct HUDItem: Identifiable {
    let action: ShortcutAction
    let label: String
    let tooltip: String
    let startsGroup: Bool
    var id: String { action.rawValue }

    @MainActor static func all() -> [HUDItem] {
        let entries: [(ShortcutAction, String, Bool)] = [
            (.captureArea, "Area", false),
            (.captureWindow, "Window", false),
            (.captureFullscreen, "Fullscreen", false),
            (.capturePreviousArea, "Previous Area", false),
            (.scrollingCapture, "Scrolling", true),
            (.captureText, "Text (OCR)", false),
            (.pickColor, "Pick Color", false),
            (.selfTimer, "Self-Timer", true),
            (.recordScreen, "Record", true),
        ]
        return entries.map { action, label, group in
            HUDItem(action: action, label: label, tooltip: action.tooltip, startsGroup: group)
        }
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    let items = HUDItem.all()
    @Published var focus = 0
    @Published var appeared = false
    /// Keeps the Area picker open after each shot. Only for the next Area capture.
    @Published var repeatArea = false
    var choose: (Int) -> Void = { _ in }

    func move(_ step: Int) {
        focus = (focus + step + items.count) % items.count
    }
}

// MARK: - Controller

@MainActor
private final class HUDController {
    private let perform: AllInOneHUD.Perform
    private let released: () -> Void
    private let model = HUDModel()
    private let panel: FloatingPanel
    private var previousApp: NSRunningApplication?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var closing = false

    init(perform: @escaping AllInOneHUD.Perform, released: @escaping () -> Void) {
        self.perform = perform
        self.released = released
        panel = FloatingPanel(frame: .zero, level: .statusBar, canBeKey: true, collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        model.choose = { [weak self] index in
            guard let self else { return }
            self.choose(self.model.items[index].action)
        }
    }

    func present() {
        previousApp = FocusKeeper.frontmostExternal()

        let host = NSHostingView(rootView: HUDBarView(model: model))
        let size = host.fittingSize
        panel.contentView = host
        let screen = NSScreen.underMouse.visibleFrame
        let frame = CGRect(x: (screen.midX - size.width / 2).rounded(), y: screen.minY + 72, width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        panel.present(makeKey: true, from: frame.offsetBy(dx: 0, dy: -14))
        FocusKeeper.activateSelf()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { model.appeared = true }

        installMonitors()
    }

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated { self.handleKey(box.event) }
            return consumed ? nil : event
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            MainActor.assumeIsolated { if box.event.window !== self.panel { self.dismiss() } }
            return event
        }
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.dismiss() }
        }
        monitors = [keys, clicks, outside].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 53: dismiss()                                   // Esc
        case 123: model.move(-1)                             // left
        case 124, 48: model.move(1)                          // right, tab
        case 36, 76: model.choose(model.focus)               // return, enter
        case 15: model.repeatArea.toggle()                   // R
        default: return true
        }
        return true
    }

    // `close` drops the last strong reference to this controller (`released`), so the completions
    // capture what they need by value instead of reaching back through a weak self.
    func choose(_ action: ShortcutAction, target: ActionLink.Target? = nil) {
        guard !closing else { return }
        let repeating = model.repeatArea && action == .captureArea
        let previousApp = previousApp
        let perform = perform
        close {
            Task { @MainActor in
                // Hand focus back first so the capture sees the app the user was in.
                await FocusKeeper.restore(previousApp)
                perform(action, target, repeating)
            }
        }
    }

    func dismiss() {
        guard !closing else { return }
        let previousApp = previousApp
        let panel = panel
        close {
            // Only when Screenme still holds focus because of this bar: not after a click into another app,
            // and not when a picker opened by a shortcut has taken the keyboard.
            guard NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === panel else { return }
            Task { @MainActor in await FocusKeeper.restore(previousApp) }
        }
    }

    private func close(then completion: @escaping () -> Void) {
        closing = true
        released()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.dismiss(completion: completion)
    }
}

// MARK: - Views

private struct HUDBarView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if item.startsGroup {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 34)
                        .padding(.horizontal, 5)
                }
                Button { model.choose(index) } label: { HUDButtonLabel(item: item) }
                    .buttonStyle(HUDButtonStyle(.tile(focused: model.focus == index)))
                    .help(item.tooltip)
                    .onHover { inside in if inside { model.focus = index } }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 34)
                .padding(.horizontal, 5)
            Button { model.repeatArea.toggle() } label: { HUDRepeatLabel(on: model.repeatArea) }
                .buttonStyle(HUDButtonStyle(.tile(focused: model.repeatArea)))
                .help(title: "Repeat Area  R", "Keeps the Area picker open after each shot, to capture the same or an adjusted area again. Return shoots again, Esc closes. Applies to the next Area capture.")
                .accessibilityLabel("Repeat Area")
                .accessibilityValue(model.repeatArea ? "On" : "Off")
        }
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .scaleEffect(model.appeared ? 1 : 0.95)
        .opacity(model.appeared ? 1 : 0)
        .background(VisualEffectBackground(material: .popover).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
    }
}

/// The Repeat toggle at the end of the bar: lit while it is on.
private struct HUDRepeatLabel: View {
    let on: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "repeat")
                .font(.system(size: 21, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .frame(height: 26)
            Text("Repeat")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.85))
        }
        .frame(width: 82, height: 64)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HUDButtonLabel: View {
    let item: HUDItem

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: item.action.symbol)
                .font(.system(size: 21, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.action == .recordScreen ? Color.red : Color.primary)
                .frame(height: 26)
            Text(item.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(Color.primary.opacity(0.85))
        }
        .frame(width: 82, height: 64)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
