import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Scrolling capture: as soon as the area is picked, Screenme scrolls the content under it to the end and
/// stitches the frames into one tall image. Nothing of Screenme is on screen meanwhile. A click anywhere
/// stops it and keeps what was stitched; Esc cancels. Without Accessibility access Screenme cannot scroll,
/// so the user scrolls and clicks at the end.
/// One at a time: only `CaptureCoordinator` calls it, inside its busy window.
@MainActor
enum ScrollingCapture {
    /// Returns the stitched image, or nil when cancelled. `forAgent`: nobody is there to scroll or click, so missing
    /// Accessibility access or losing track of the content throws instead of returning what was stitched.
    static func run(_ target: CaptureTarget, forAgent: Bool = false) async throws -> CGImage? {
        let (filter, configuration) = try await target.streamSetup(showsCursor: false, retina: Prefs[Pref.retinaResolution])
        let session = ScrollSession(frame: target.cocoaFrame, filter: filter, configuration: configuration, forAgent: forAgent)
        let image = await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            Task { @MainActor in await session.cancel() }
        }
        if let failure = session.failure { throw AgentError(failure) }
        return image
    }
}

// MARK: - Session

/// One scrolling capture, from the stream starting to the end of the page, a click, or Esc.
@MainActor
final class ScrollSession {
    private enum Message {
        static let needsAccess = "Scrolling capture needs Accessibility access to scroll by itself. Allow Screenme in System Settings."
        static let scrollYourself = "Scroll to the end, then click"
        static let lost = "The scrolling capture lost its place in the content; try a smaller area or window"
    }

    private let frame: CGRect
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let forAgent: Bool
    private let engine = ScrollStitchEngine()
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var autoTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var rows = 0
    private var lastAdvance = Date()
    /// The last frames did not match the content seen so far.
    private var lost = false
    private var finishing = false
    /// Why the capture gave up.
    private(set) var failure: String?

    init(frame: CGRect, filter: SCContentFilter, configuration: SCStreamConfiguration, forAgent: Bool) {
        self.frame = frame
        self.filter = filter
        self.configuration = configuration
        self.forAgent = forAgent
    }

    func run() async -> CGImage? {
        engine.onUpdate = { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { await start() }
        }
    }

    // MARK: Start and stop

    private func start() async {
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: engine)
        do {
            try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
            try await stream.startCapture()
        } catch {
            guard !finishing else { return }
            failure = "Could not start the scrolling capture: \(error.localizedDescription)"
            await cancel()
            return
        }
        // Cancelled while the stream started: nothing will stop it later, so stop it now.
        guard !finishing else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        lastAdvance = Date()
        watchForStop()

        if Permission.accessibility.isGranted {
            autoTask = Task { [weak self] in await self?.autoScrollLoop() }
        } else if forAgent {
            failure = Message.needsAccess
            await cancel()
        } else {
            Permission.accessibility.request()
            Toast.show(Message.scrollYourself, symbol: "arrow.down.to.line", duration: 3)
        }
    }

    /// A click anywhere keeps what was stitched; Esc throws it away. Esc is only seen with Accessibility access.
    private func watchForStop() {
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in await self?.done() }
        }) { monitors.append(click) }
        if let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in await self?.cancel() }
        }) { monitors.append(key) }
    }

    func done() async {
        guard !finishing, stream != nil else { return }
        finishing = true
        await stop()
        close(with: engine.finish())
    }

    func cancel() async {
        guard !finishing else { return }
        finishing = true
        await stop()
        engine.cancel()
        close(with: nil)
    }

    private func stop() async {
        autoTask?.cancel()
        autoTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        engine.onUpdate = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    private func close(with image: CGImage?) {
        continuation?.resume(returning: image)
        continuation = nil
    }

    // MARK: Updates

    private func apply(_ update: ScrollStitchEngine.Update) {
        guard !finishing else { return }
        if update.rows != rows { lastAdvance = Date() }
        rows = update.rows
        switch update.outcome {
        case .limit:
            Task { await done() }
        case .lost:
            lost = true
        case .first, .advanced, .still, .scrolledBack:
            lost = false
        }
    }

    // MARK: Auto-scroll

    /// Posts pixel scroll events over the middle of the area until the page stops moving, then finishes.
    private func autoScrollLoop() async {
        let height = CaptureTarget.primaryHeight
        let point = CGPoint(x: frame.midX, y: height - frame.midY)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        try? await Task.sleep(for: .milliseconds(150))

        var direction: Int32 = -1 // negative scrolls the page down
        let step: Int32 = 18
        let started = Date()
        var checkedDirection = false
        lastAdvance = Date()

        while !Task.isCancelled {
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: step * direction, wheel2: 0, wheel3: 0) {
                event.location = point
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(16))

            // If the first second only moved content backwards, the scroll direction is flipped.
            if !checkedDirection, Date().timeIntervalSince(started) > 1.0 {
                checkedDirection = true
                let (advances, backs) = engine.motionCounts()
                if backs > 3, advances == 0 { direction = -direction }
                lastAdvance = Date()
            }
            if checkedDirection, Date().timeIntervalSince(lastAdvance) > 1.6 {
                // Outside this task, which `done` and `cancel` cancel. For an agent, content that stopped
                // matching is not the end of the page; a person gets what was stitched.
                if forAgent, lost {
                    failure = Message.lost
                    Task { await self.cancel() }
                } else {
                    Task { await self.done() }
                }
                return
            }
        }
    }
}
