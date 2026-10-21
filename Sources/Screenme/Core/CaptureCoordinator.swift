import AppKit
import ScreenCaptureKit

/// Routes every user action (shortcut, menu, All-in-One, Quick Access) to the module that does it.
/// Modules never call each other's selection or capture code directly: they go through here.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    /// True from the moment a capture starts until its file is delivered, including the GIF conversion
    /// after a recording stops. Only one capture runs at a time.
    private var busy = false
    /// Last area captured, for "Capture Previous Area".
    private var previousArea: CaptureTarget?
    private(set) var lastCapture: CaptureItem?

    /// `target` comes from a `screenme://` link and replaces the selection overlay.
    func perform(_ action: ShortcutAction, target: ActionLink.Target? = nil) {
        if action == .recordScreen, RecordingController.shared.isRecording {
            Task { await stopRecording() }
            return
        }
        guard !RecordingController.shared.isRecording else { return }
        if action.requiresScreenRecording, !Permission.screenRecording.isGranted {
            OnboardingWindow.show()
            return
        }

        // Instant actions open or toggle something and return: they never wait for a capture.
        switch action {
        case .allInOne:
            // Not over a capture in progress; the shortcut still closes an open bar.
            guard !busy || AllInOneHUD.isOpen else { return }
            AllInOneHUD.show { [weak self] choice in self?.perform(choice) }
            return
        case .pinLastCapture:
            if let lastCapture { PinWindow.pin(lastCapture) }
            return
        case .openHistory:
            HistoryWindow.show()
            return
        case .toggleDesktopIcons:
            DesktopIcons.toggle()
            return
        default:
            break
        }

        // A capture shortcut pressed while the All-in-One bar is open picks that capture from the bar.
        if AllInOneHUD.isOpen {
            AllInOneHUD.choose(action)
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await capture(action, target: target)
            } catch {
                report(error)
            }
        }
    }

    private func capture(_ action: ShortcutAction, target: ActionLink.Target?) async throws {
        // Recordings have their own setting; text recognition does not keep a picture;
        // Pick Color and Measure read the screen as the user sees it.
        let hidesIcons = Prefs[Pref.hideDesktopIconsInShots] && !DesktopIcons.isHidden
            && ![.recordScreen, .captureText, .translateText, .pickColor, .measure].contains(action)
        if hidesIcons {
            DesktopIcons.setHidden(true)
            try? await Task.sleep(for: .milliseconds(700))
        }
        defer { if hidesIcons { DesktopIcons.setHidden(false) } }

        switch action {
        case .allInOne, .pinLastCapture, .openHistory, .toggleDesktopIcons:
            return // handled in `perform`

        case .captureArea:
            guard let result = try await select(.screenshot, target) else { return }
            try await finishScreenshot(result)

        case .captureWindow:
            guard let result = try await select(.window, target) else { return }
            try await finishScreenshot(result)

        case .captureFullscreen:
            try await finishScreenshot(SelectionResult(target: .display(.underMouse), frozenImage: nil))

        case .capturePreviousArea:
            guard let previousArea else { throw ScreenmeError.nothingToCapture }
            try await finishScreenshot(SelectionResult(target: previousArea, frozenImage: nil))

        case .selfTimer:
            guard let result = try await select(.screenshot, target) else { return }
            // Clicks go through the ring: the user may be opening the menu or hover state to capture.
            guard await Countdown.run(seconds: Prefs[Pref.selfTimerSeconds], around: result.target.cocoaFrame,
                                      cancelsOnClick: false) else { return }
            try await finishScreenshot(SelectionResult(target: result.target, frozenImage: nil))

        case .captureText:
            guard let result = try await select(.text, target) else { return }
            let image = try await image(for: result)
            let text = try await TextRecognizer.recognize(image)
            if text.isEmpty {
                Toast.show("No text found", symbol: "text.viewfinder")
            } else {
                Clipboard.copyText(text)
                Toast.show("Text copied", symbol: "doc.on.clipboard")
            }

        case .translateText:
            guard let result = try await select(.text, target) else { return }
            let text = try await TextRecognizer.recognize(try await image(for: result))
            guard !text.isEmpty else {
                Toast.show("No text found", symbol: "text.viewfinder")
                return
            }
            let translation: TextTranslation
            do {
                translation = try await TextTranslator.translate(text)
            } catch TranslateError.sameLanguage(let language) {
                Clipboard.copyText(text)
                Toast.show("Already in \(language): text copied", symbol: "doc.on.clipboard")
                return
            }
            Clipboard.copyText(translation.text)
            TranslationPanel.show(translation, near: result.target.cocoaFrame)

        case .pickColor:
            await ScreenColorPicker.run()

        case .measure:
            try await MeasureOverlay.run()

        case .scrollingCapture:
            guard let result = try await select(.scrolling, target) else { return }
            guard let image = try await ScrollingCapture.run(result.target) else { return }
            try deliver(image)

        case .recordScreen:
            guard let result = try await select(.recording, target) else { return }
            try await RecordingController.shared.start(result.target, asksForSettings: target == nil)
        }
    }

    /// What the user picks in the overlay, or what a link names.
    private func select(_ mode: SelectionMode, _ target: ActionLink.Target?) async throws -> SelectionResult? {
        guard let target else { return await SelectionOverlay.select(mode) }
        return SelectionResult(target: try await target.captureTarget(), frozenImage: nil)
    }

    // MARK: Screenshots

    private func finishScreenshot(_ result: SelectionResult) async throws {
        if case .area = result.target { previousArea = result.target }
        try deliver(try await image(for: result))
    }

    private func image(for result: SelectionResult) async throws -> CGImage {
        let image = if let frozen = result.frozenImage { frozen } else { try await Capturer.screenshot(result.target) }
        return Notch.hidden(in: image, of: result.target)
    }

    /// Writes an image capture and runs the after-capture actions.
    func deliver(_ image: CGImage) throws {
        let item = CaptureItem(url: try Storage.write(Watermark.applied(to: image)), kind: .image)
        Sounds.shutter()
        afterCapture(item)
    }

    // MARK: Recordings

    /// Stops the recording and delivers it. Busy until then, so a new capture cannot start
    /// while a recording is still turning into a GIF.
    func stopRecording() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let item = await RecordingController.shared.stop() else { return }
        afterCapture(item)
    }

    // MARK: After capture

    /// Runs the user's after-capture actions. Editors call this too when they save a new version.
    func afterCapture(_ item: CaptureItem) {
        lastCapture = item
        CaptureHistory.shared.add(item)
        switch item.kind {
        case .image:
            if Prefs[Pref.afterShotCopy] { Clipboard.copy(item) }
            if Prefs[Pref.afterShotSave] { _ = try? Storage.save(item.url) }
            if Prefs[Pref.afterShotPin] { PinWindow.pin(item) }
            if Prefs[Pref.afterShotOpenEditor] {
                AnnotationEditor.open(item)
            } else if Prefs[Pref.afterShotQuickAccess] {
                QuickAccess.shared.show(item)
            }
        case .video, .gif:
            if Prefs[Pref.afterRecordingCopy] { Clipboard.copy(item) }
            if Prefs[Pref.afterRecordingSave] { _ = try? Storage.save(item.url) }
            if Prefs[Pref.afterRecordingOpenEditor] && item.kind == .video {
                VideoEditor.open(item)
            } else if Prefs[Pref.afterRecordingQuickAccess] {
                QuickAccess.shared.show(item)
            }
        }
    }

    /// A capture that no longer exists (moved to the Trash) is no longer the one to pin.
    func forget(_ item: CaptureItem) {
        if lastCapture?.url == item.url { lastCapture = nil }
    }

    // MARK: Helpers

    func report(_ error: Error) {
        let alert = NSAlert(error: error)
        if !Permission.screenRecording.isGranted {
            alert.informativeText = "Screenme needs Screen Recording permission. Open Settings > Permissions to turn it on."
        }
        FocusKeeper.activateSelf()
        alert.runModal()
    }
}
