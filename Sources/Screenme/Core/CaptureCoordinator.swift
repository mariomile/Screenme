import AppKit
import ScreenCaptureKit

/// Routes every user action (shortcut, menu, All-in-One, Quick Access) to the module that does it.
/// Modules never call each other's selection or capture code directly: they go through here.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let state = AppState.shared
    private var busy = false
    /// Last area captured, for "Capture Previous Area".
    private var previousArea: CaptureTarget?
    private(set) var lastCapture: CaptureItem?

    func perform(_ action: ShortcutAction) {
        if action == .recordScreen, RecordingController.shared.isRecording {
            Task { await stopRecording() }
            return
        }
        guard !busy, !RecordingController.shared.isRecording else { return }
        let needsScreen: Set<ShortcutAction> = [.openHistory, .toggleDesktopIcons, .pinLastCapture]
        if !needsScreen.contains(action), !state.screenRecordingGranted {
            OnboardingWindow.show()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await run(action)
            } catch {
                report(error)
            }
        }
    }

    private func run(_ action: ShortcutAction) async throws {
        switch action {
        case .allInOne:
            busy = false
            AllInOneHUD.show { [weak self] choice in self?.perform(choice) }

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

        case .pinLastCapture:
            if let lastCapture { PinWindow.pin(lastCapture) }

        case .openHistory:
            HistoryWindow.show()

        case .toggleDesktopIcons:
            DesktopIcons.toggle()
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

    func stopRecording() async {
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

    // MARK: Helpers

    func report(_ error: Error) {
        let alert = NSAlert(error: error)
        if !state.screenRecordingGranted {
            alert.informativeText = "Screenme needs Screen Recording permission. Open Settings > Permissions to turn it on."
        }
        FocusKeeper.activateSelf()
        alert.runModal()
    }
}
