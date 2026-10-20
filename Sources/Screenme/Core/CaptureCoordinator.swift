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

    func perform(_ action: ShortcutAction) {
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

        // While the All-in-One bar is open, only the bar starts a capture, once it has closed.
        guard !busy, !AllInOneHUD.isOpen else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await capture(action)
            } catch {
                report(error)
            }
        }
    }

    private func capture(_ action: ShortcutAction) async throws {
        switch action {
        case .allInOne, .pinLastCapture, .openHistory, .toggleDesktopIcons:
            return // handled in `perform`

        case .captureArea:
            guard let result = await SelectionOverlay.select(.screenshot) else { return }
            try await finishScreenshot(result)

        case .captureWindow:
            guard let result = await SelectionOverlay.select(.window) else { return }
            try await finishScreenshot(result)

        case .captureFullscreen:
            try await finishScreenshot(SelectionResult(target: .display(.underMouse), frozenImage: nil))

        case .capturePreviousArea:
            guard let previousArea else { throw ScreenmeError.nothingToCapture }
            try await finishScreenshot(SelectionResult(target: previousArea, frozenImage: nil))

        case .selfTimer:
            guard let result = await SelectionOverlay.select(.screenshot) else { return }
            guard await Countdown.run(seconds: Prefs[Pref.selfTimerSeconds], around: result.target.cocoaFrame) else { return }
            try await finishScreenshot(SelectionResult(target: result.target, frozenImage: nil))

        case .captureText:
            guard let result = await SelectionOverlay.select(.text) else { return }
            let image = try await image(for: result)
            let text = try await TextRecognizer.recognize(image)
            if text.isEmpty {
                Toast.show("No text found", symbol: "text.viewfinder")
            } else {
                Clipboard.copyText(text)
                Toast.show("Text copied", symbol: "doc.on.clipboard")
            }

        case .scrollingCapture:
            guard let result = await SelectionOverlay.select(.scrolling) else { return }
            guard let image = try await ScrollingCapture.run(result.target) else { return }
            try deliver(image)

        case .recordScreen:
            guard let result = await SelectionOverlay.select(.recording) else { return }
            try await RecordingController.shared.start(result.target)
        }
    }

    // MARK: Screenshots

    private func finishScreenshot(_ result: SelectionResult) async throws {
        if case .area = result.target { previousArea = result.target }
        try deliver(try await image(for: result))
    }

    private func image(for result: SelectionResult) async throws -> CGImage {
        if let frozen = result.frozenImage { return frozen }
        return try await Capturer.screenshot(result.target)
    }

    /// Writes an image capture and runs the after-capture actions.
    func deliver(_ image: CGImage) throws {
        let item = CaptureItem(url: try Storage.write(image), kind: .image)
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
            if Prefs[Pref.afterShotOpenEditor] {
                AnnotationEditor.open(item)
            } else if Prefs[Pref.afterShotQuickAccess] {
                QuickAccess.shared.show(item)
            }
        case .video, .gif:
            if Prefs[Pref.afterRecordingCopy] { Clipboard.copy(item) }
            if Prefs[Pref.afterRecordingSave] { _ = try? Storage.save(item.url) }
            if Prefs[Pref.afterRecordingQuickAccess] { QuickAccess.shared.show(item) }
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
