import AppKit
import SwiftUI

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
                    Text(Duration.format(clock.elapsed(at: context.date), tenths: true))
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
