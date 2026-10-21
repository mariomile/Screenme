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

    private enum Phase {
        case idle
        /// Pre-record bar, countdown, starting the stream.
        case preparing
        case running(Session)
        /// Stopping, discarding or restarting. The controls do nothing until it is over.
        case transitioning(Session)
    }

    private var phase = Phase.idle {
        didSet {
            if AppState.shared.isRecording != isRecording { AppState.shared.isRecording = isRecording }
        }
    }

    var isRecording: Bool {
        switch phase {
        case .running, .transitioning: true
        case .idle, .preparing: false
        }
    }

    /// A restart in progress. Stop waits for it, so pressing Stop right after Restart still stops.
    private var restarting: Task<Void, Never>?

    private var running: Session? {
        if case .running(let session) = phase { return session }
        return nil
    }

    private init() {}

    // MARK: Start

    /// Only `CaptureCoordinator` calls this, inside its busy window, so there is never a second start.
    /// `usingSavedSettings` (a `screenme://` link) skips the pre-record bar and records with the saved settings.
    func start(_ target: CaptureTarget, usingSavedSettings: Bool = false) async throws {
        guard case .idle = phase else { return }
        phase = .preparing
        // The pre-record bar activates Screenme to receive Return and Esc; the user's app gets focus back after.
        let previousApp = FocusKeeper.frontmostExternal()
        var session: Session?
        defer {
            if case .preparing = phase {
                await session?.tearDown(keep: false)
                await FocusKeeper.restore(previousApp)
                phase = .idle
            }
        }

        let chosen = usingSavedSettings ? PreRecordUI.savedChoice(for: target) : await PreRecordUI(target: target).run()
        guard let (settings, webcam) = chosen else { return }
        let preparing = Session(target: target, settings: settings, webcam: webcam)
        session = preparing

        await preparing.hideDesktopIcons()
        if settings.countdown > 0 {
            guard await Countdown.run(seconds: settings.countdown, around: target.cocoaFrame) else { return }
        }

        // Capture with the user's app in front, so it records as active and keeps the keyboard.
        await FocusKeeper.restore(previousApp)
        try await preparing.begin()
        phase = .running(preparing)
        if Prefs[Pref.playSounds] { NSSound(named: "Pop")?.play() }
    }

    // MARK: Stop

    /// Stops, finishes the file and returns it. Returns nil when nothing was recorded or it was discarded.
    func stop() async -> CaptureItem? {
        if let restarting { await restarting.value }
        guard let session = takeRunning() else { return nil }
        let size = session.size
        guard let url = await end(session, keep: true) else { return nil }
        if session.settings.format == .gif { return await convertToGIF(url, size: size) }
        return CaptureItem(url: url, kind: .video)
    }

    /// Moves the running session into a transition, so no other control can act on it meanwhile.
    private func takeRunning() -> Session? {
        guard let session = running else { return nil }
        phase = .transitioning(session)
        return session
    }

    /// The one way a recording ends: stop, discard, a failed restart. Releases everything the session holds,
    /// keeps or deletes the file, and goes back to idle.
    private func end(_ session: Session, keep: Bool) async -> URL? {
        let url = await session.tearDown(keep: keep)
        phase = .idle
        return url
    }

    /// `size` is the recording's pixel size; the GIF gets the video editor's starting size for it.
    private func convertToGIF(_ video: URL, size: CGSize) async -> CaptureItem? {
        let toast = Toast.progress("Creating GIF")
        defer { toast.finish() }
        do {
            let duration = try await AVURLAsset(url: video).load(.duration)
            let gif = try await GIFExporter.export(video, range: CMTimeRange(start: .zero, duration: duration),
                                                   size: ExportResolution.gif(for: size).outputSize(for: size),
                                                   fps: 15, quality: .high) { value in
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

    fileprivate func togglePause() {
        guard let session = running else { return }
        session.setPaused(!session.clock.isPaused)
    }

    /// Throws the current take away and starts again with the same settings, without a countdown.
    fileprivate func restart() async {
        guard let session = takeRunning() else { return }
        let task = Task {
            do {
                try await session.restart()
                phase = .running(session)
            } catch {
                _ = await end(session, keep: false)
                CaptureCoordinator.shared.report(error)
            }
        }
        restarting = task
        await task.value
        restarting = nil
    }

    fileprivate func confirmDiscard() {
        guard let session = running else { return }
        // The recording waits while the question is open.
        let wasPaused = session.clock.isPaused
        session.setPaused(true)

        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The recording will be deleted. This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons[0].hasDestructiveAction = true
        FocusKeeper.activateSelf()
        let discard = alert.runModal() == .alertFirstButtonReturn

        guard running === session else { return }
        if discard {
            _ = takeRunning()
            Task { _ = await end(session, keep: false) }
        } else {
            session.setPaused(wasPaused)
        }
    }

    /// The stream stopped or the writer failed: stop the way the user would, which keeps what was recorded
    /// when the file is still good, and tell them. Stopping from the macOS menu bar is not an error.
    fileprivate func recorderFailed(_ error: Error) async {
        guard running != nil else { return }
        await CaptureCoordinator.shared.stopRecording()
        if (error as? SCStreamError)?.code == .userStopped { return }
        CaptureCoordinator.shared.report(error)
    }
}

/// One recording and everything it holds, acquired in order. `tearDown` releases all of it.
@MainActor
private final class Session {
    let target: CaptureTarget
    let settings: RecordingSettings
    let clock = RecordingClock()
    private var webcam: WebcamBubble?
    private var hidIcons = false
    private var effects: RecordingEffects?
    private var watermark: WatermarkOverlay?
    private var recorder: StreamRecorder?
    private var outline: RecordingOutline?
    private var bar: RecordingControlBar?

    init(target: CaptureTarget, settings: RecordingSettings, webcam: WebcamBubble?) {
        self.target = target
        self.settings = settings
        self.webcam = webcam
    }

    /// The pixel size of the recording.
    var size: CGSize {
        guard let setup = recorder?.setup else { return .zero }
        return CGSize(width: setup.width, height: setup.height)
    }

    /// Hides the desktop icons for the duration when the settings ask for it.
    func hideDesktopIcons() async {
        guard settings.hideDesktopIcons else { return }
        // A countdown gives the covers time to fade in.
        hidIcons = await DesktopIcons.hideForCapture(settle: settings.countdown == 0)
    }

    /// Puts up the filmed overlays, starts capturing, then shows the outline and the controls.
    func begin() async throws {
        let frame = target.cocoaFrame
        if settings.showKeystrokes && !Permission.accessibility.isGranted {
            Toast.show("Keystrokes need Accessibility access", symbol: "keyboard", duration: 3)
        }
        let showKeys = settings.showKeystrokes && Permission.accessibility.isGranted
        if settings.highlightClicks || showKeys {
            let overlay = RecordingEffects(frame: frame, highlightClicks: settings.highlightClicks, showKeystrokes: showKeys)
            overlay.show()
            effects = overlay
        }

        watermark = WatermarkOverlay(frame: frame)
        watermark?.show()

        let overlays: [NSWindow] = [effects?.panel, webcam?.panel, watermark?.panel].compactMap { $0 }
        // Let the window server register the overlay windows before ScreenCaptureKit looks for them.
        if !overlays.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        recorder = try await makeRecorder(CaptureSetup.make(for: target, settings: settings, overlays: overlays))
        effects?.start()

        let insideFrame = if case .display = target { true } else { false }
        let outline = RecordingOutline(frame: frame, insideFrame: insideFrame)
        outline.show()
        self.outline = outline

        // The clock exists since the pre-record bar closed; the recording starts now.
        clock.reset()
        let controller = RecordingController.shared
        let bar = RecordingControlBar(clock: clock, area: frame, screen: Placement.screen(for: target),
                                      pause: { controller.togglePause() },
                                      stop: { Task { await CaptureCoordinator.shared.stopRecording() } },
                                      restart: { Task { await controller.restart() } },
                                      discard: { controller.confirmDiscard() })
        bar.show()
        self.bar = bar
    }

    /// A recorder for `setup`, already capturing.
    private func makeRecorder(_ setup: CaptureSetup) async throws -> StreamRecorder {
        let recorder = StreamRecorder(url: Storage.newURL(extension: "mp4"), setup: setup, quality: settings.quality)
        recorder.onFailure = { error in
            Task { @MainActor in await RecordingController.shared.recorderFailed(error) }
        }
        try await recorder.start()
        return recorder
    }

    func setPaused(_ paused: Bool) {
        guard let recorder, clock.isPaused != paused else { return }
        if paused {
            recorder.pause()
            clock.pause()
        } else {
            recorder.resume()
            clock.resume()
        }
        outline?.setPaused(paused)
    }

    /// Throws the current take away and starts a new one with the same setup.
    func restart() async throws {
        guard let previous = recorder else { return }
        recorder = nil
        _ = await previous.finish(discard: true)
        recorder = try await makeRecorder(previous.setup)
        clock.reset()
        outline?.setPaused(false)
    }

    /// Releases everything, newest first. The controls go at once; the filmed overlays stay until the recorder
    /// has stopped, so the last frames still show them. Returns the file when `keep` is set and something was recorded.
    @discardableResult
    func tearDown(keep: Bool) async -> URL? {
        bar?.close()
        bar = nil
        outline?.close()
        outline = nil
        let recorder = self.recorder
        self.recorder = nil
        let url = await recorder?.finish(discard: !keep)
        effects?.stop()
        effects = nil
        watermark?.close()
        watermark = nil
        webcam?.close()
        webcam = nil
        if hidIcons { DesktopIcons.setHidden(false) }
        hidIcons = false
        return url
    }
}
