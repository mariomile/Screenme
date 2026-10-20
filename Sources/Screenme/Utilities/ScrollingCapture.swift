import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// Scrolling capture: while the content under `target` scrolls, frames are stitched into one tall image.
/// A floating panel next to the area has Start, Auto-scroll, Done and Cancel, plus a live preview.
@MainActor
enum ScrollingCapture {
    private static var active: ScrollSession?

    /// Returns the stitched image, or nil when cancelled.
    static func run(_ target: CaptureTarget) async throws -> CGImage? {
        guard active == nil else { return nil }
        let (filter, configuration) = try await target.streamSetup(showsCursor: false, retina: Prefs[Pref.retinaResolution])
        let session = ScrollSession(frame: target.cocoaFrame, filter: filter, configuration: configuration)
        active = session
        defer { active = nil }
        return await session.run()
    }
}

// MARK: - Session

@MainActor
private final class ScrollSession: ObservableObject {
    enum Phase { case ready, capturing, finishing }

    @Published var phase: Phase = .ready
    @Published var status = Message.ready
    @Published var rows = 0
    @Published var preview: CGImage?
    @Published var isAutoScrolling = false

    enum Message {
        static let ready = "Place the page where you want it, press Start, then scroll the area. Or let Screenme scroll for you."
        static let capturing = "Scroll slowly. Screenme stitches as you go."
        static let lost = "Lost track of the content. Scroll back a little."
        static let auto = "Scrolling for you. Press Done any time."
        static let end = "Reached the end of the page. Press Done."
        static let limit = "Reached the maximum height. Press Done."
        static let needsAccess = "Auto-scroll needs Accessibility access. Allow Screenme in System Settings, or scroll yourself."
    }

    private let frame: CGRect
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let engine = ScrollStitchEngine()
    private var stream: SCStream?
    private var sink: ScrollFrameSink?
    private var panel: NSPanel?
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
        phase = .capturing
        status = Message.capturing
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let sink = ScrollFrameSink(engine: engine)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            // Cancel was pressed while the stream started: nothing will stop it later, so stop it now.
            guard phase == .capturing else {
                try? await stream.stopCapture()
                return
            }
            self.sink = sink
            self.stream = stream
            lastAdvance = Date()
        } catch {
            guard phase == .capturing else { return }
            phase = .ready
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func toggleAutoScroll() async {
        if isAutoScrolling {
            stopAutoScroll()
            status = Message.capturing
            return
        }
        guard accessibilityGranted(prompt: true) else {
            status = Message.needsAccess
            return
        }
        if phase == .ready { await start() }
        guard phase == .capturing, stream != nil else { return }
        isAutoScrolling = true
        status = Message.auto
        autoTask = Task { [weak self] in await self?.autoScrollLoop() }
    }

    func done() async {
        guard phase == .capturing, stream != nil else { return }
        phase = .finishing
        stopAutoScroll()
        await stopStream()
        let image = engine.finish()
        close(with: image)
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
        sink = nil
    }

    private func close(with image: CGImage?) {
        let panel = panel
        self.panel = nil
        if let panel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        }
        continuation?.resume(returning: image)
        continuation = nil
    }

    // MARK: Updates

    private func apply(_ update: ScrollStitchEngine.Update) {
        guard phase == .capturing else { return }
        if update.rows != rows { lastAdvance = Date() }
        rows = update.rows
        if let image = update.preview { preview = image }
        if update.limitReached {
            stopAutoScroll()
            status = Message.limit
        } else if update.lost {
            status = Message.lost
        } else if status == Message.lost {
            status = isAutoScrolling ? Message.auto : Message.capturing
        }
    }

    // MARK: Auto-scroll

    private func stopAutoScroll() {
        autoTask?.cancel()
        autoTask = nil
        isAutoScrolling = false
    }

    private func accessibilityGranted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
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
                status = Message.end
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

        let panel = NSPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollPanelView(session: self))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }
}

// MARK: - Frame pipeline

/// Receives ScreenCaptureKit frames on its own queue.
private final class ScrollFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.mariomiletta.Screenme.scrolling", qos: .userInitiated)
    private let engine: ScrollStitchEngine

    init(engine: ScrollStitchEngine) {
        self.engine = engine
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        engine.process(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Screenme: scrolling capture stream stopped: \(error.localizedDescription)")
    }
}

/// Owns the stitcher and serializes access to it between the frame queue and the main actor.
private final class ScrollStitchEngine: @unchecked Sendable {
    struct Update {
        var rows: Int
        var preview: CGImage?
        var lost: Bool
        var limitReached: Bool
    }

    var onUpdate: (@Sendable (Update) -> Void)?

    private let lock = NSLock()
    private var stitcher: ScrollStitcher?
    private var closed = false
    private var lastPublish = Date.distantPast
    private var publishedRows = -1
    private var lost = false
    private var limit = false
    private var advances = 0
    private var backs = 0

    func process(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        if stitcher == nil {
            stitcher = ScrollStitcher(width: width, height: height)
            if let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() {
                stitcher?.colorSpace = space
            } else if let space = CGColorSpace(name: CGColorSpace.sRGB) {
                stitcher?.colorSpace = space
            }
        }
        guard let stitcher, stitcher.width == width, stitcher.height == height else { return }

        let outcome = stitcher.add(base.assumingMemoryBound(to: UInt8.self), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        switch outcome {
        case .lost: lost = true
        case .advanced: lost = false; advances += 1
        case .scrolledBack: lost = false; backs += 1
        case .limit: limit = true
        case .first, .still: lost = false
        }

        let now = Date()
        let changed = stitcher.totalRows != publishedRows
        guard now.timeIntervalSince(lastPublish) > 0.2 || outcome == .lost || outcome == .limit else { return }
        lastPublish = now
        let image = changed ? stitcher.previewImage() : nil
        publishedRows = stitcher.totalRows
        onUpdate?(Update(rows: stitcher.totalRows, preview: image, lost: lost, limitReached: limit))
    }

    /// Frames that moved the page forward and backward since the last call.
    func motionCounts() -> (advances: Int, backs: Int) {
        lock.lock()
        defer { lock.unlock() }
        defer { advances = 0; backs = 0 }
        return (advances, backs)
    }

    func finish() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return stitcher?.finish()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        stitcher = nil
    }
}

// MARK: - Panel UI

private struct ScrollPanelView: View {
    @ObservedObject var session: ScrollSession

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
            Divider().opacity(0.5)
            controls
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: Preview

    private var previewColumn: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let preview = session.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 22, weight: .light))
                    Text("Live preview")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if session.rows > 0 {
                Text("\(session.rows.formatted()) px")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(12)
        .frame(width: 136)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .foregroundStyle(Color.accentColor)
                Text("Scrolling Capture").font(.system(size: 13, weight: .semibold))
            }
            .padding(.top, 14)

            Text(session.status)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: session.status)

            Spacer(minLength: 8)

            VStack(spacing: 7) {
                startButton
                Button { Task { await session.toggleAutoScroll() } } label: {
                    Label(session.isAutoScrolling ? "Stop Auto-scroll" : "Auto-scroll",
                          systemImage: session.isAutoScrolling ? "stop.fill" : "arrow.down.to.line")
                }
                .buttonStyle(ScrollPanelButtonStyle(kind: .secondary))
                .disabled(session.phase == .finishing)

                Button { Task { await session.done() } } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(ScrollPanelButtonStyle(kind: session.phase == .capturing ? .primary : .secondary))
                .disabled(session.phase != .capturing)

                Button("Cancel") { Task { await session.cancel() } }
                    .buttonStyle(ScrollPanelButtonStyle(kind: .plain))
                    .disabled(session.phase == .finishing)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var startButton: some View {
        Button { Task { await session.start() } } label: {
            if session.phase == .ready {
                Label("Start", systemImage: "play.fill")
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Capturing")
                }
            }
        }
        .buttonStyle(ScrollPanelButtonStyle(kind: session.phase == .ready ? .primary : .secondary))
        .disabled(session.phase != .ready)
    }
}

private struct ScrollPanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .plain: .secondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.accentColor.opacity(pressed ? 0.75 : 1)
        case .secondary: Color.primary.opacity(pressed ? 0.16 : 0.09)
        case .plain: Color.primary.opacity(pressed ? 0.08 : 0)
        }
    }
}
