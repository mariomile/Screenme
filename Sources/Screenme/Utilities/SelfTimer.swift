import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A large countdown with a ring, centered on the area about to be captured.
/// Esc cancels. The panel is gone before `countdown` returns, so it never appears in the shot.
@MainActor
enum SelfTimer {
    private static var session: SelfTimerSession?

    /// Returns false when cancelled (Esc), true when the countdown reached zero.
    static func countdown(seconds: Int, around frame: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        session?.finish(false)
        return await withCheckedContinuation { continuation in
            let session = SelfTimerSession(seconds: seconds, frame: frame) { result in
                continuation.resume(returning: result)
            }
            self.session = session
            session.start()
        }
    }

    fileprivate static func sessionEnded(_ ended: SelfTimerSession) {
        if session === ended { session = nil }
    }

    fileprivate static func escapePressed() {
        session?.finish(false)
    }
}

// MARK: - SelfTimerSession

@MainActor
private final class SelfTimerSession {
    private let seconds: Int
    private let frame: CGRect
    private var completion: ((Bool) -> Void)?
    private let model = SelfTimerModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining: Int

    init(seconds: Int, frame: CGRect, completion: @escaping (Bool) -> Void) {
        self.seconds = seconds
        self.remaining = seconds
        self.frame = frame
        self.completion = completion
    }

    func start() {
        let side: CGFloat = 220
        let rect = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SelfTimerView(model: model))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        SelfTimerEscapeKey.register()
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        remaining -= 1
        if remaining <= 0 {
            finish(true)
        } else {
            tick()
        }
    }

    private func tick() {
        model.show(remaining)
        if Prefs[Pref.playSounds] {
            (NSSound(named: NSSound.Name("Tink")) ?? NSSound(named: NSSound.Name("Pop")))?.play()
        }
    }

    func finish(_ completed: Bool) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate()
        timer = nil
        SelfTimerEscapeKey.unregister()
        SelfTimer.sessionEnded(self)

        // Fade out and make sure the window is off screen before the capture starts.
        guard let panel else { completion(completed); return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                // Give the window server a beat to drop the window from the next frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { completion(completed) }
            }
        })
    }
}

// MARK: - View

@MainActor
private final class SelfTimerModel: ObservableObject {
    @Published var number = 0
    @Published var progress = 1.0

    func show(_ value: Int) {
        // Reset the ring without animating, then deplete it over the second.
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 1 }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { number = value }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 0.96)) { self.progress = 0 }
        }
    }
}

private struct SelfTimerView: View {
    @ObservedObject var model: SelfTimerModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.62))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)

            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 7)
                .padding(22)

            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .scaleEffect(x: -1, y: 1)
                .padding(22)

            Text("\(model.number)")
                .font(.system(size: 78, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .scaleEffect(1)
        }
        .padding(10)
        .scaleEffect(appeared ? 1 : 0.78)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { appeared = true } }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Esc

/// Esc as a Carbon hot key while the countdown runs: works without focus or Accessibility,
/// so cancelling never steals focus from the app being captured.
@MainActor
private enum SelfTimerEscapeKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static let signature = OSType(0x5354_4D45) // 'STME'

    static func register() {
        installHandler()
        guard ref == nil else { return }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &newRef) == noErr {
            ref = newRef
        }
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == SelfTimerEscapeKey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { SelfTimer.escapePressed() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
