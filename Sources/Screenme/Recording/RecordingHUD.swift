import AppKit
import SwiftUI

// MARK: - Countdown

/// The big number over the area before recording starts. Esc or a click cancels.
@MainActor
final class CountdownHUD {
    private final class Model: ObservableObject {
        @Published var number: Int
        init(number: Int) { self.number = number }
    }

    private var cancelled = false
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?

    /// Returns false when the user cancelled.
    func run(seconds: Int, around frame: CGRect) async -> Bool {
        let model = Model(number: seconds)
        let side: CGFloat = 200
        let screen = NSScreen.at(CGPoint(x: frame.midX, y: frame.midY))
        var rect = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        rect.origin.x = min(max(rect.minX, screen.frame.minX), screen.frame.maxX - side)
        rect.origin.y = min(max(rect.minY, screen.frame.minY), screen.frame.maxY - side)

        let panel = FloatingPanel(frame: rect, level: .popUpMenu, canBeKey: true, hasShadow: false)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model, cancel: { [weak self] in self?.cancelled = true }))
        panel.present(makeKey: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelled = true; return nil }
            return event
        }
        if Accessibility.trusted {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let code = event.keyCode
                MainActor.assumeIsolated { if code == 53 { self?.cancelled = true } }
            }
        }

        outer: for number in stride(from: seconds, through: 1, by: -1) {
            model.number = number
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if cancelled { break outer }
            }
        }

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        keyMonitor = nil
        globalKeyMonitor = nil
        panel.dismiss()
        return !cancelled
    }

    private struct CountdownView: View {
        @ObservedObject var model: Model
        let cancel: () -> Void

        var body: some View {
            VStack(spacing: 6) {
                Text("\(model.number)")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .id(model.number)
                    .transition(.asymmetric(insertion: .scale(scale: 1.35).combined(with: .opacity),
                                            removal: .scale(scale: 0.7).combined(with: .opacity)))
                Text("Esc to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.number)
            .frame(width: 180, height: 180)
            .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
            .frame(width: 200, height: 200)
            .contentShape(Rectangle())
            .onTapGesture(perform: cancel)
        }
    }
}

// MARK: - Recording control bar

/// Elapsed recording time that does not count paused time.
@MainActor
final class RecordingClock: ObservableObject {
    @Published private(set) var isPaused = false
    private var accumulated: TimeInterval = 0
    private var runningSince: Date? = Date()

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    func pause() {
        guard !isPaused else { return }
        accumulated = elapsed()
        runningSince = nil
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        runningSince = Date()
        isPaused = false
    }

    func reset() {
        accumulated = 0
        runningSince = Date()
        isPaused = false
    }
}

/// The small draggable bar with time, pause, stop, restart and discard.
@MainActor
final class RecordingControlBar {
    private let panel: FloatingPanel

    init(clock: RecordingClock, area: CGRect, screen: NSScreen,
         pause: @escaping () -> Void, stop: @escaping () -> Void,
         restart: @escaping () -> Void, discard: @escaping () -> Void) {
        let view = NSHostingView(rootView: ControlBarView(clock: clock, togglePause: pause, stop: stop, restart: restart, discard: discard))
        let size = view.fittingSize
        panel = FloatingPanel(frame: Placement.barFrame(size: size, near: area, on: screen), level: .popUpMenu)
        panel.isMovableByWindowBackground = true
        panel.contentView = view
    }

    func show() { panel.present() }
    func close() { panel.dismiss() }

    private struct ControlBarView: View {
        @ObservedObject var clock: RecordingClock
        let togglePause: () -> Void
        let stop: () -> Void
        let restart: () -> Void
        let discard: () -> Void

        var body: some View {
            HStack(spacing: 4) {
                Button(action: stop) {
                    ZStack {
                        Circle().fill(Color(red: 1, green: 0.27, blue: 0.23))
                        RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10, height: 10)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop recording")

                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(Self.format(clock.elapsed(at: context.date)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 52, alignment: .leading)
                }
                .padding(.horizontal, 6)

                PulseDot(paused: clock.isPaused)
                    .padding(.trailing, 6)

                ControlButton(symbol: clock.isPaused ? "play.fill" : "pause.fill", help: clock.isPaused ? "Resume" : "Pause", action: togglePause)
                ControlButton(symbol: "arrow.counterclockwise", help: "Restart recording", action: restart)
                ControlButton(symbol: "trash", help: "Discard recording", action: discard)
            }
            .padding(6)
            .background(VisualEffectBackground().clipShape(Capsule()))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
            .fixedSize()
        }

        static func format(_ seconds: TimeInterval) -> String {
            let total = Int(seconds)
            let tenths = Int((seconds - Double(total)) * 10)
            if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
            return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
        }
    }

    private struct PulseDot: View {
        let paused: Bool
        @State private var on = false

        var body: some View {
            Circle()
                .fill(paused ? Color.orange : Color(red: 1, green: 0.27, blue: 0.23))
                .frame(width: 8, height: 8)
                .opacity(paused ? 1 : (on ? 1 : 0.3))
                .animation(paused ? .default : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
                .onAppear { on = true }
        }
    }

    private struct ControlButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}
