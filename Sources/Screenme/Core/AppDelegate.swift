import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let coordinator = CaptureCoordinator.shared
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app: no menu bar item, shortcuts or onboarding next to the installed copy.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AppState.shared.$isRecording
            .sink { [weak self] recording in self?.updateStatusIcon(recording: recording) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusVisibility() }
            .store(in: &subscriptions)

        let hotKeys = HotKeyCenter.shared
        hotKeys.onTrigger = { [weak self] action in self?.coordinator.perform(action) }
        hotKeys.registerAll()

        CaptureHistory.shared.prune()
        if AppState.shared.needsSetup { OnboardingWindow.show() }
    }

    /// `screenme://capture-area` and the like run that action, for Shortcuts, Raycast or scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch ActionLink(url: url) {
            case .perform(let action, let target): coordinator.perform(action, target: target)
            case .settings(let tab): SettingsWindow.show(tab: tab)
            case nil: continue
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    // MARK: Status item

    /// The icon can be hidden in Settings; it always shows while recording, as the Stop button.
    /// `recording` defaults to the current state; `$isRecording` publishes before the property changes.
    private func updateStatusVisibility(recording: Bool? = nil) {
        let visible = Prefs[Pref.showMenuBarIcon] || (recording ?? AppState.shared.isRecording)
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
    }

    private func updateStatusIcon(recording: Bool) {
        defer { updateStatusVisibility(recording: recording) }
        let button = statusItem.button
        if recording {
            button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button?.contentTintColor = .systemRed
            statusItem.menu = nil
            button?.target = self
            button?.action = #selector(stopRecording)
        } else {
            button?.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenme")
            button?.contentTintColor = nil
            button?.action = nil
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
        }
    }

    @objc private func stopRecording() {
        coordinator.perform(.recordScreen)
    }

    /// Rebuilt every time it opens so it always shows the current shortcuts.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let groups: [[ShortcutAction]] = [
            [.allInOne],
            [.captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea, .selfTimer],
            [.scrollingCapture, .captureText, .translateText],
            [.pickColor, .measure],
            [.recordScreen],
            [.pinLastCapture, .openHistory, .toggleDesktopIcons],
        ]
        for group in groups {
            for action in group {
                let item = NSMenuItem(title: action == .toggleDesktopIcons && DesktopIcons.isHidden ? "Show Desktop Icons" : action.title,
                                      action: #selector(performAction(_:)), keyEquivalent: "")
                item.representedObject = action.rawValue
                item.target = self
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                if let combo = ShortcutStore.combo(for: action) {
                    item.keyEquivalent = combo.keyEquivalent
                    item.keyEquivalentModifierMask = combo.eventModifiers
                }
                if action == .pinLastCapture { item.isEnabled = coordinator.lastCapture != nil }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Screenme", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        // Let the menu close before an overlay takes the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.coordinator.perform(action) }
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
