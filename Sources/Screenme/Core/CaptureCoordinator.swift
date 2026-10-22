import AppKit
import ScreenCaptureKit

/// Routes every user action (shortcut, menu, `screenme://` link, All-in-One, Quick Access) to the module that does it.
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

    private init() {
        // A capture that no longer exists (moved to the Trash) is no longer the one to pin.
        Sidecar.onTrash { [weak self] url in
            if self?.lastCapture?.url == url { self?.lastCapture = nil }
        }
    }

    /// `target` comes from a `screenme://` link and replaces the selection overlay. `repeating`: an Area capture picked
    /// from the All-in-One bar with its Repeat toggle on.
    func perform(_ action: ShortcutAction, target: ActionLink.Target? = nil, repeating: Bool = false) {
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
            AllInOneHUD.show { [weak self] choice, target, repeating in self?.perform(choice, target: target, repeating: repeating) }
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

        // A capture shortcut or link while the All-in-One bar is open picks that capture from the bar, with the link's target.
        if AllInOneHUD.isOpen {
            AllInOneHUD.choose(action, target: target)
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                // A link's target replaces the picker, so there is nothing to repeat.
                try await capture(action, target: target, repeating: repeating && target == nil)
            } catch {
                report(error)
            }
        }
    }

    /// `repeating`: an Area capture whose picker stays open for several shots.
    private func capture(_ action: ShortcutAction, target: ActionLink.Target?, repeating: Bool = false) async throws {
        var hidIcons = false
        if action.writesScreenshot, Prefs[Pref.hideDesktopIconsInShots] {
            hidIcons = await DesktopIcons.hideForCapture(settle: true)
        }
        defer { if hidIcons { DesktopIcons.setHidden(false) } }

        switch action {
        case .allInOne, .pinLastCapture, .openHistory, .toggleDesktopIcons:
            return // handled in `perform`

        case .captureArea:
            if repeating {
                // Each shot goes through the normal after-capture flow; a failed one is a toast and the picker stays.
                await SelectionOverlay.selectRepeatedly { [weak self] result in
                    do { try await self?.finishScreenshot(result) } catch { self?.report(error) }
                }
                return
            }
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
            guard let recognized = try await recognizedText(target) else { return }
            Clipboard.copyText(recognized.text)
            Toast.show("Text copied", symbol: "doc.on.clipboard")

        case .translateText:
            guard let recognized = try await recognizedText(target) else { return }
            try await TranslationPanel.translateAndShow(recognized.text, near: recognized.area)

        case .pickColor:
            await ScreenColorPicker.run()

        case .measure:
            try await MeasureOverlay.run()

        case .scrollingCapture:
            guard let result = try await select(.scrolling, target) else { return }
            guard let image = try await ScrollingCapture.run(result.target) else { return }
            try await deliver(image)

        case .recordScreen:
            guard let result = try await select(.recording, target) else { return }
            try await RecordingController.shared.start(result.target, usingSavedSettings: target != nil)
        }
    }

    /// What the user picks in the overlay, or what a link names.
    private func select(_ mode: SelectionMode, _ target: ActionLink.Target?) async throws -> SelectionResult? {
        guard let target else { return await SelectionOverlay.select(mode) }
        return SelectionResult(target: try await target.captureTarget(), frozenImage: nil)
    }

    /// The text in what the user picks or the link names, and where it was (global Cocoa coordinates).
    /// Nil when the user cancels or there is no text, which a toast says.
    private func recognizedText(_ target: ActionLink.Target?) async throws -> (text: String, area: CGRect)? {
        guard let result = try await select(.text, target) else { return nil }
        let text = try await TextRecognizer.recognize(try await image(for: result))
        guard !text.isEmpty else {
            Toast.show("No text found", symbol: "text.viewfinder")
            return nil
        }
        return (text, result.target.cocoaFrame)
    }

    // MARK: Screenshots

    private func finishScreenshot(_ result: SelectionResult) async throws {
        if case .area = result.target { previousArea = result.target }
        try await deliver(try await image(for: result), from: result.target)
    }

    /// The frozen picture when the picker had one, otherwise a fresh capture.
    private func image(for result: SelectionResult) async throws -> CGImage {
        if let frozen = result.frozenImage { return frozen }
        return try await Capturer.screenshot(result.target)
    }

    /// Writes an image capture and runs the after-capture actions. The notch cover, the watermark and the encoding
    /// run off the main thread; meanwhile a Quick Access card already shows `image` from memory and waits for the file.
    /// `target`: where the picture came from, for its notch cover and its context (Copy for AI).
    func deliver(_ image: CGImage, from target: CaptureTarget? = nil) async throws {
        let item = CaptureItem(url: Storage.newURL(extension: Prefs[Pref.imageFormat].fileExtension), kind: .image)
        if let target { CaptureContexts.record(target, for: item.url) }
        let cover = target.flatMap(Notch.cover(for:))
        Sounds.shutter()
        let file = Task.detached(priority: .userInitiated) {
            try Storage.write(Watermark.applied(to: cover?.applied(to: image) ?? image), to: item.url)
            return item.url
        }
        try await afterCapture(item, preview: image, file: file)
    }

    // MARK: Recordings

    /// Stops the recording and delivers it. Busy until then, so a new capture cannot start
    /// while a recording is still turning into a GIF.
    func stopRecording() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let item = await RecordingController.shared.stop() else { return }
        // The file is complete: nothing is left to wait for or to fail.
        try? await afterCapture(item, file: Task { item.url })
        // Outside the busy window: transcribing can take a while, and a new capture need not wait for it.
        if Prefs[Pref.afterRecordingAIReport], CaptureAction.reportForAI.isAvailable(for: item.kind) {
            Task { await CaptureAction.reportForAI.perform(item) }
        }
    }

    // MARK: After capture

    /// Makes `item` the last capture (for Pin Last Capture) and adds it to History, without the after-capture
    /// actions. For a new file that opens somewhere itself, like a combined image.
    func record(_ item: CaptureItem) {
        lastCapture = item
        CaptureHistory.shared.add(item)
    }

    /// Runs the user's after-capture actions on a new capture. A Quick Access card shows at once, from `preview` while
    /// `file` is still being written; everything else waits for the file, and nothing happens when writing it fails.
    private func afterCapture(_ item: CaptureItem, preview: CGImage? = nil, file: Task<URL, Error>) async throws {
        let plan = AfterCapture.plan(for: item.kind)
        if plan.presentation == .quickAccess { QuickAccess.shared.show(item, preview: preview, file: file) }
        _ = try await file.value
        record(item)
        if plan.copy { Clipboard.copy(item) }
        if plan.save { _ = try? Storage.save(item.url) }
        if plan.pin { PinWindow.pin(item) }
        if plan.presentation == .editor { item.kind == .image ? AnnotationEditor.open(item) : VideoEditor.open(item) }
    }

    // MARK: Helpers

    /// A toast, so a failed capture never blocks the next shortcut, link or CLI call. Only a missing
    /// Screen Recording permission, which the user must fix, is an alert.
    func report(_ error: Error) {
        if !Permission.screenRecording.isGranted {
            Feedback.alert(error.localizedDescription,
                           detail: "Screenme needs Screen Recording permission. Open Settings > Permissions to turn it on.")
        } else {
            Feedback.failure(error.localizedDescription, duration: 3.2)
        }
    }
}

/// What happens to a new capture, from the after-capture settings: the file actions, then where it opens.
struct AfterCapture: Equatable {
    enum Presentation { case editor, quickAccess, none }

    var copy = false
    var save = false
    var pin = false
    var presentation = Presentation.none

    /// The editor opens instead of Quick Access. GIFs have no editor, so a GIF recording falls back to Quick Access.
    static func plan(for kind: CaptureItem.Kind) -> AfterCapture {
        switch kind {
        case .image:
            AfterCapture(copy: Prefs[Pref.afterShotCopy], save: Prefs[Pref.afterShotSave], pin: Prefs[Pref.afterShotPin],
                         presentation: Prefs[Pref.afterShotOpenEditor] ? .editor : Prefs[Pref.afterShotQuickAccess] ? .quickAccess : .none)
        case .video, .gif:
            AfterCapture(copy: Prefs[Pref.afterRecordingCopy], save: Prefs[Pref.afterRecordingSave],
                         presentation: Prefs[Pref.afterRecordingOpenEditor] && kind == .video ? .editor
                             : Prefs[Pref.afterRecordingQuickAccess] ? .quickAccess : .none)
        }
    }
}
