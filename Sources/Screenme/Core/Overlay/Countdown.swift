import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A large countdown with a ring, centered on the area about to be captured or recorded.
/// Esc (or a click on it) cancels without taking focus from the user's app. The panel is gone before `run` returns,
/// so it never appears in the shot.
@MainActor
enum Countdown {
    private static var session: CountdownSession?

    /// Returns false when cancelled (Esc), true when the countdown reached zero.
    static func run(seconds: Int, around frame: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        session?.finish(false)
        return await withCheckedContinuation { continuation in
            let session = CountdownSession(seconds: seconds, frame: frame) { result in
                continuation.resume(returning: result)
            }
            self.session = session
            session.start()
        }
    }

    fileprivate static func sessionEnded(_ ended: CountdownSession) {
        if session === ended { session = nil }
    }
}

// MARK: - Session

@MainActor
private final class CountdownSession {
    private let frame: CGRect
    private var completion: ((Bool) -> Void)?
    private let model = CountdownModel()
    private var panel: FloatingPanel?
    private var timer: Timer?
    private var escape: TemporaryHotKey?
    private var remaining: Int

    init(seconds: Int, frame: CGRect, completion: @escaping (Bool) -> Void) {
        self.remaining = seconds
        self.frame = frame
        self.completion = completion
    }

    func start() {
        let side: CGFloat = 220
        let screen = NSScreen.at(CGPoint(x: frame.midX, y: frame.midY)).frame
        let rect = CGRect(x: min(max(frame.midX - side / 2, screen.minX), screen.maxX - side),
                          y: min(max(frame.midY - side / 2, screen.minY), screen.maxY - side),
                          width: side, height: side)
        let panel = FloatingPanel(frame: rect, level: .screenSaver, canBeKey: true, hasShadow: false,
                                  collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
        panel.contentView = NSHostingView(rootView: CountdownView(model: model) { [weak self] in self?.finish(false) })
        panel.present()
        self.panel = panel

        escape = HotKeyCenter.shared.registerTemporary(keyCode: UInt32(kVK_Escape)) { [weak self] in self?.finish(false) }
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
        HotKeyCenter.shared.unregisterTemporary(escape)
        escape = nil
        Countdown.sessionEnded(self)

        // Fade out and make sure the window is off screen before the capture starts.
        guard let panel else { completion(completed); return }
        self.panel = nil
        panel.dismiss {
            // Give the window server a beat to drop the window from the next frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { completion(completed) }
        }
    }
}

// MARK: - View

@MainActor
private final class CountdownModel: ObservableObject {
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

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let cancel: () -> Void
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
        .contentShape(Circle())
        .onTapGesture(perform: cancel)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { appeared = true } }
        .environment(\.colorScheme, .dark)
    }
}
