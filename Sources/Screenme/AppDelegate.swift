import AppKit
import Carbon.HIToolbox

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeyCenter()
    private let recorder = Recorder()
    private var selection: SelectionOverlay?
    private let state = AppState.shared
    private let windows = WindowPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        showIdleStatus()

        let modifiers = cmdKey | shiftKey
        hotKeys.register(keyCode: kVK_ANSI_1, modifiers: modifiers) { [weak self] in self?.captureSelection() }
        hotKeys.register(keyCode: kVK_ANSI_2, modifiers: modifiers) { [weak self] in self?.toggleRecording() }
        state.retryShortcuts = { [hotKeys] in hotKeys.retry() }
        state.shortcutsRegistered = hotKeys.allRegistered

        if state.needsSetup { showOnboarding() }
    }

    // MARK: Windows

    @objc private func showOnboarding() {
        if state.onboardingDone {
            // Coming back to fix something: jump to the first step that needs it.
            state.onboardingStep = !state.screenRecordingGranted ? 1 : (!state.shortcutsRegistered ? 2 : 0)
        }
        windows.close("settings")
        windows.show("onboarding", title: "Welcome to Screenme", size: CGSize(width: 600, height: 480)) {
            OnboardingView(state: state) { [weak self] in
                self?.state.onboardingDone = true
                self?.state.onboardingStep = 0
                self?.windows.close("onboarding")
            }
        }
    }

    @objc private func showSettings() {
        windows.show("settings", title: "Screenme Settings", size: CGSize(width: 500, height: 500)) {
            SettingsView(state: state) { [weak self] in self?.showOnboarding() }
        }
    }

    // MARK: Status item

    private func showIdleStatus() {
        let menu = NSMenu()
        menu.addItem(item("Capture Area or Window", key: "1", action: #selector(captureSelection)))
        menu.addItem(item("Capture Screen", key: "", action: #selector(captureScreen)))
        menu.addItem(item("Record Area or Window", key: "2", action: #selector(toggleRecording)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",", action: #selector(showSettings), modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(item("Quit Screenme", key: "q", action: #selector(quit), modifiers: .command))
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenme")
        statusItem.button?.contentTintColor = nil
        statusItem.button?.action = nil
    }

    private func showRecordingStatus() {
        statusItem.menu = nil
        statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        statusItem.button?.contentTintColor = .systemRed
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleRecording)
    }

    private func item(_ title: String, key: String, action: Selector, modifiers: NSEvent.ModifierFlags = [.command, .shift]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func captureSelection() {
        guard !recorder.isRecording else { return }
        guard state.screenRecordingGranted else { return showOnboarding() }
        select { target in
            Task { await self.capture(target) }
        }
    }

    @objc private func captureScreen() {
        guard state.screenRecordingGranted else { return showOnboarding() }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        Task { await capture(.display(screen)) }
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            Task {
                guard let url = await recorder.stop() else { return }
                showIdleStatus()
                QuickAccess.shared.show(CaptureItem(url: url, kind: .video))
            }
            return
        }
        guard state.screenRecordingGranted else { return showOnboarding() }
        select { target in
            Task {
                do {
                    try await self.recorder.start(target)
                    self.showRecordingStatus()
                } catch {
                    self.report(error)
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func select(_ completion: @escaping (CaptureTarget) -> Void) {
        guard selection == nil else { return }
        Task {
            do {
                let overlay = try await SelectionOverlay.make()
                selection = overlay
                overlay.begin { target in
                    self.selection = nil
                    if let target { completion(target) }
                }
            } catch {
                report(error)
            }
        }
    }

    @MainActor
    private func capture(_ target: CaptureTarget) async {
        do {
            let image = try await Capturer.screenshot(target)
            let url = try Storage.writePNG(image)
            if state.copyAfterCapture { Clipboard.copyImage(at: url) }
            QuickAccess.shared.show(CaptureItem(url: url, kind: .image))
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.informativeText = "If this is a permission problem, enable Screenme in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
