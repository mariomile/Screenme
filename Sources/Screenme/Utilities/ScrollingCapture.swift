import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// Scrolling capture: while the content under `target` scrolls, frames are stitched into one tall image.
/// A floating panel next to the area has Start, Auto-scroll, Done and Cancel, plus a live preview.
/// One at a time: only `CaptureCoordinator` calls it, inside its busy window.
@MainActor
enum ScrollingCapture {
    /// Returns the stitched image, or nil when cancelled.
    static func run(_ target: CaptureTarget) async throws -> CGImage? {
        let (filter, configuration) = try await target.streamSetup(showsCursor: false, retina: Prefs[Pref.retinaResolution])
        return await ScrollSession(frame: target.cocoaFrame, filter: filter, configuration: configuration).run()
    }
}

// MARK: - Session

/// One scrolling capture, from the panel opening to Done or Cancel. It keeps the facts
/// (phase, lost, limit, end of page, error, auto-scrolling) and the panel's message follows from them.
@MainActor
final class ScrollSession: ObservableObject {
    enum Phase { case ready, starting, capturing, finishing }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var rows = 0
    @Published private(set) var preview: CGImage?
    @Published private(set) var isAutoScrolling = false
    /// The last frames did not match the content seen so far.
    @Published private var lost = false
    @Published private var limitReached = false
    /// Auto-scroll stopped because the page stopped moving.
    @Published private var endReached = false
    /// Auto-scroll was asked for without Accessibility access.
    @Published private var needsAccess = false
    /// Why the stream could not start.
    @Published private var error: String?

    private enum Message {
        static let ready = "Place the page where you want it, press Start, then scroll the area. Or let Screenme scroll for you."
        static let capturing = "Scroll slowly. Screenme stitches as you go."
        static let lost = "Lost track of the content. Scroll back a little."
        static let auto = "Scrolling for you. Press Done any time."
        static let end = "Reached the end of the page. Press Done."
        static let limit = "Reached the maximum height. Press Done."
        static let needsAccess = "Auto-scroll needs Accessibility access. Allow Screenme in System Settings, or scroll yourself."
    }

    /// What the panel tells the user, from the facts above.
    var status: String {
        if let error { return "Could not start: \(error)" }
        if limitReached { return Message.limit }
        if lost { return Message.lost }
        if needsAccess { return Message.needsAccess }
        if endReached { return Message.end }
        if isAutoScrolling { return Message.auto }
        return phase == .ready ? Message.ready : Message.capturing
    }

    private let frame: CGRect
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let engine = ScrollStitchEngine()
    private var stream: SCStream?
    private var panel: FloatingPanel?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var autoTask: Task<Void, Never>?
    private var lastAdvance = Date()

    init(frame: CGRect, filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.frame = frame
        self.filter = filter
        self.configuration = configuration
    }

    func run() async -> CGImage? {
        engine.onUpdate = { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showPanel()
        }
    }

    // MARK: Controls

    func start() async {
        guard phase == .ready else { return }
        phase = .starting
        error = nil
        needsAccess = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: engine)
        do {
            try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
            try await stream.startCapture()
        } catch {
            guard phase == .starting else { return }
            phase = .ready
            self.error = error.localizedDescription
            return
        }
        // Cancel was pressed while the stream started: nothing will stop it later, so stop it now.
        guard phase == .starting else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        phase = .capturing
        lastAdvance = Date()
    }

    func toggleAutoScroll() async {
        if isAutoScrolling {
            stopAutoScroll()
            return
        }
        guard Permission.accessibility.isGranted else {
            Permission.accessibility.request()
            error = nil
            needsAccess = true
            return
        }
        if phase == .ready { await start() }
        guard phase == .capturing, stream != nil else { return }
        needsAccess = false
        endReached = false
        isAutoScrolling = true
        autoTask = Task { [weak self] in await self?.autoScrollLoop() }
    }

    func done() async {
        guard phase == .capturing, stream != nil else { return }
        phase = .finishing
        stopAutoScroll()
        await stopStream()
        close(with: engine.finish())
    }

    func cancel() async {
        guard phase != .finishing else { return }
        phase = .finishing
        stopAutoScroll()
        await stopStream()
        engine.cancel()
        close(with: nil)
    }

    private func stopStream() async {
        engine.onUpdate = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    private func close(with image: CGImage?) {
        panel?.dismiss()
        panel = nil
        continuation?.resume(returning: image)
        continuation = nil
    }

    // MARK: Updates

    private func apply(_ update: ScrollStitchEngine.Update) {
        // The first frame can arrive before startCapture returns; it carries the first preview.
        guard phase == .capturing || phase == .starting else { return }
        if update.rows != rows { lastAdvance = Date() }
        rows = update.rows
        if let image = update.preview { preview = image }
        switch update.outcome {
        case .limit:
            limitReached = true
            stopAutoScroll()
        case .lost:
            lost = true
        case .first, .advanced, .still, .scrolledBack:
            lost = false
        }
    }

    // MARK: Auto-scroll

    private func stopAutoScroll() {
        autoTask?.cancel()
        autoTask = nil
        isAutoScrolling = false
    }

    /// Posts pixel scroll events over the middle of the area until the page stops moving.
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
                stopAutoScroll()
                endReached = true
                return
            }
        }
    }

    // MARK: Panel

    private func showPanel() {
        let size = CGSize(width: 344, height: 420)
        let screen = NSScreen.at(CGPoint(x: frame.midX, y: frame.midY))
        let visible = screen.visibleFrame
        let height = min(max(frame.height, size.height), visible.height - 24)
        let gap: CGFloat = 14

        var x = frame.maxX + gap
        if x + size.width > visible.maxX - 8 { x = frame.minX - gap - size.width }
        if x < visible.minX + 8 { x = visible.maxX - size.width - 16 } // no room beside the area: sit over its edge
        let top = min(frame.maxY, visible.maxY - 12)
        let y = max(visible.minY + 12, top - height)

        let panel = FloatingPanel(frame: CGRect(x: x, y: y, width: size.width, height: height), level: .statusBar)
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: ScrollPanelView(session: self))
        panel.present()
        self.panel = panel
    }
}
