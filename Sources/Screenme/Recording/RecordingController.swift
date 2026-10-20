import AppKit
import AVFoundation
import ScreenCaptureKit

/// Screen recording: pre-record bar, countdown, capture with pause, and the controls around it.
///
/// `start` returns once recording has begun (or the user cancelled). `stop` finishes the file and
/// returns it; the coordinator then runs the after-capture actions.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var active: ActiveRecording?

    var isRecording: Bool { active != nil }

    private init() {}

    // MARK: Start

    /// Only `CaptureCoordinator` calls this, inside its busy window, so there is never a second start.
    func start(_ target: CaptureTarget) async throws {

        // The pre-record bar activates Screenme to receive Return and Esc; the user's app gets focus back after.
        let previousApp = FocusKeeper.frontmostExternal()

        // 1. Pre-record bar.
        let preRecord = PreRecordUI(target: target)
        let decision = await preRecord.run()
        preRecord.dismiss()
        guard decision == .record else {
            preRecord.closeWebcam()
            await FocusKeeper.restore(previousApp)
            return
        }
        let settings = RecordingSettings.current()

        // 2. Desktop icons: hidden for the duration, restored afterwards.
        var hidIcons = false
        if settings.hideDesktopIcons, !DesktopIcons.isHidden {
            DesktopIcons.setHidden(true)
            hidIcons = true
            if settings.countdown == 0 { try? await Task.sleep(for: .milliseconds(700)) }
        }

        // 3. Countdown.
        if settings.countdown > 0 {
            let completed = await Countdown.run(seconds: settings.countdown, around: target.cocoaFrame)
            guard completed else {
                preRecord.closeWebcam()
                if hidIcons { DesktopIcons.setHidden(false) }
                await FocusKeeper.restore(previousApp)
                return
            }
        }

        // 4. Capture, with the user's app in front so it records as active and keeps the keyboard.
        await FocusKeeper.restore(previousApp)
        let webcam = settings.webcam ? preRecord.takeWebcam() : nil
        if !settings.webcam { preRecord.closeWebcam() }
        do {
            active = try await begin(target, settings: settings, webcam: webcam, hidIcons: hidIcons)
        } catch {
            webcam?.close()
            if hidIcons { DesktopIcons.setHidden(false) }
            throw error
        }
        AppState.shared.isRecording = true
        if Prefs[Pref.playSounds] { NSSound(named: "Pop")?.play() }
    }

    private func begin(_ target: CaptureTarget, settings: RecordingSettings, webcam: WebcamBubble?, hidIcons: Bool) async throws -> ActiveRecording {
        let frame = target.cocoaFrame

        var effects: RecordingEffects?
        if settings.showKeystrokes && !Permission.accessibility.isGranted {
            Toast.show("Keystrokes need Accessibility access", symbol: "keyboard", duration: 3)
        }
        let showKeys = settings.showKeystrokes && Permission.accessibility.isGranted
        if settings.highlightClicks || showKeys {
            let overlay = RecordingEffects(frame: frame, highlightClicks: settings.highlightClicks, showKeystrokes: showKeys)
            overlay.show()
            effects = overlay
        }

        let setup: CaptureSetup
        let recorder: StreamRecorder
        do {
            let overlays: [NSWindow] = [effects?.panel, webcam?.panel].compactMap { $0 }
            // Let the window server register the overlay windows before ScreenCaptureKit looks for them.
            if !overlays.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            setup = try await CaptureSetup.make(for: target, settings: settings, overlays: overlays)
            recorder = StreamRecorder(url: Storage.newURL(extension: "mp4"), setup: setup, quality: settings.quality)
            try await recorder.start()
        } catch {
            effects?.stop()
            throw error
        }

        let recording = ActiveRecording(target: target, settings: settings, setup: setup, recorder: recorder)
        recording.effects = effects
        recording.webcam = webcam
        recording.hidIcons = hidIcons
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in await self?.recorderFailed(error) }
        }

        effects?.start()
        let outline: RecordingOutline
        if case .display = target { outline = RecordingOutline(frame: frame, insideFrame: true) } else { outline = RecordingOutline(frame: frame, insideFrame: false) }
        outline.show()
        recording.outline = outline

        let bar = RecordingControlBar(clock: recording.clock, area: frame, screen: Placement.screen(for: target),
                                      pause: { [weak self] in self?.togglePause() },
                                      stop: { Task { await CaptureCoordinator.shared.stopRecording() } },
                                      restart: { [weak self] in Task { await self?.restart() } },
                                      discard: { [weak self] in self?.confirmDiscard() })
        bar.show()
        recording.controlBar = bar
        return recording
    }

    // MARK: Stop

    /// Stops, finishes the file and returns it. Returns nil when nothing was recorded or it was discarded.
    func stop() async -> CaptureItem? {
        guard let recording = active, !recording.isEnding else { return nil }
        recording.isEnding = true
        guard let url = await finish(recording, discard: false) else { return nil }
        if recording.settings.format == .gif { return await convertToGIF(url) }
        return CaptureItem(url: url, kind: .video)
    }

    private func discard() async {
        guard let recording = active, !recording.isEnding else { return }
        recording.isEnding = true
        _ = await finish(recording, discard: true)
    }

    /// Takes the controls down, finishes the file and resets the state. Returns the file's URL.
    private func finish(_ recording: ActiveRecording, discard: Bool) async -> URL? {
        recording.controlBar?.close()
        recording.outline?.close()
        let url = await recording.recorder.finish(discard: discard)
        recording.effects?.stop()
        recording.webcam?.close()
        if recording.hidIcons { DesktopIcons.setHidden(false) }
        active = nil
        AppState.shared.isRecording = false
        return url
    }

    private func convertToGIF(_ video: URL) async -> CaptureItem? {
        let toast = Toast.progress("Creating GIF")
        defer { toast.finish() }
        do {
            let gif = try await GIFExporter.export(video, fps: 15, maxWidth: 1000) { value in
                Task { @MainActor in toast.update(value) }
            }
            try? FileManager.default.removeItem(at: video)
            return CaptureItem(url: gif, kind: .gif)
        } catch {
            CaptureCoordinator.shared.report(error)
            return CaptureItem(url: video, kind: .video)
        }
    }

    // MARK: Controls

    private func togglePause() {
        guard let recording = active, !recording.isEnding, !recording.isRestarting else { return }
        recording.clock.isPaused ? resume(recording) : pause(recording)
    }

    private func pause(_ recording: ActiveRecording) {
        recording.recorder.pause()
        recording.clock.pause()
        recording.outline?.setPaused(true)
    }

    private func resume(_ recording: ActiveRecording) {
        recording.recorder.resume()
        recording.clock.resume()
        recording.outline?.setPaused(false)
    }

    /// Throws the current take away and starts again with the same settings, without a countdown.
    private func restart() async {
        guard let recording = active, !recording.isEnding, !recording.isRestarting else { return }
        recording.isRestarting = true
        defer { recording.isRestarting = false }

        _ = await recording.recorder.finish(discard: true)
        let next = StreamRecorder(url: Storage.newURL(extension: "mp4"), setup: recording.setup, quality: recording.settings.quality)
        next.onFailure = { [weak self] error in
            Task { @MainActor in await self?.recorderFailed(error) }
        }
        do {
            try await next.start()
            // Stop or discard ran while the new stream was starting: it finished the old recorder, so drop this one.
            guard active === recording, !recording.isEnding else {
                _ = await next.finish(discard: true)
                return
            }
            recording.recorder = next
            recording.clock.reset()
            recording.outline?.setPaused(false)
        } catch {
            recording.isRestarting = false
            await discard()
            CaptureCoordinator.shared.report(error)
        }
    }

    private func confirmDiscard() {
        guard let recording = active, !recording.isEnding, !recording.isRestarting else { return }
        // The recording waits while the question is open.
        let wasPaused = recording.clock.isPaused
        if !wasPaused { pause(recording) }

        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The recording will be deleted. This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons[0].hasDestructiveAction = true
        FocusKeeper.activateSelf()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await discard() }
        } else if !wasPaused, active === recording {
            resume(recording)
        }
    }

    /// The stream or the writer failed: keep what was recorded and tell the user.
    private func recorderFailed(_ error: Error) async {
        guard let recording = active, !recording.isEnding, !recording.isRestarting else { return }
        await CaptureCoordinator.shared.stopRecording()
        CaptureCoordinator.shared.report(error)
    }
}

/// Everything that exists while a recording is running.
@MainActor
private final class ActiveRecording {
    let target: CaptureTarget
    let settings: RecordingSettings
    let setup: CaptureSetup
    var recorder: StreamRecorder
    let clock = RecordingClock()
    var controlBar: RecordingControlBar?
    var outline: RecordingOutline?
    var effects: RecordingEffects?
    var webcam: WebcamBubble?
    var hidIcons = false
    var isEnding = false
    var isRestarting = false

    init(target: CaptureTarget, settings: RecordingSettings, setup: CaptureSetup, recorder: StreamRecorder) {
        self.target = target
        self.settings = settings
        self.setup = setup
        self.recorder = recorder
    }
}
