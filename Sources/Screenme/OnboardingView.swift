import AppKit
import Combine
import SwiftUI

/// Hosts SwiftUI windows (onboarding, settings) for a menu bar app.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(_ id: String, title: String, size: CGSize, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        windows.removeValue(forKey: id)?.close()
    }
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    let finish: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = ["Welcome", "Screen Recording", "Shortcuts", "Preferences", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 36)
            Group {
                switch state.onboardingStep {
                case 0: welcome
                case 1: screenRecording
                case 2: shortcuts
                case 3: preferences
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            footer
        }
        .frame(width: 600, height: 480)
        .background(.background)
        .onReceive(poll) { _ in state.refresh() }
    }

    // MARK: Steps

    private var welcome: some View {
        StepContent(symbol: "viewfinder", tint: .accentColor, title: "Welcome to Screenme",
                    text: "Capture any area or window, drop it straight into any app, record short clips. Let's set up the three things macOS needs.")
    }

    private var screenRecording: some View {
        StepContent(symbol: "rectangle.dashed.badge.record", tint: .red, title: "Allow Screen Recording",
                    text: "macOS asks every capture app for this permission. Screenme only reads the screen when you press a shortcut, and nothing leaves your Mac.") {
            if state.screenRecordingGranted {
                StatusBadge(ok: true, text: "Screen Recording is on")
            } else {
                VStack(spacing: 10) {
                    StatusBadge(ok: false, text: "Screen Recording is off")
                    HStack {
                        Button("Open System Settings") { state.requestScreenRecording() }
                            .buttonStyle(.borderedProminent)
                        Button("I turned it on: Relaunch") { state.relaunch() }
                    }
                    Text("Turn on Screenme in the list, then relaunch so macOS applies it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcuts: some View {
        StepContent(symbol: "command", tint: .indigo, title: "Your shortcuts",
                    text: "Two shortcuts, available from any app.") {
            VStack(spacing: 10) {
                ShortcutRow(keys: "⌘ ⇧ 1", label: "Capture area or window", ok: state.shortcutsRegistered)
                ShortcutRow(keys: "⌘ ⇧ 2", label: "Start or stop recording", ok: state.shortcutsRegistered)
                if !state.shortcutsRegistered {
                    let apps = state.conflictingApps.compactMap(\.localizedName)
                    Text(apps.isEmpty ? "Another app is using one of these shortcuts. Turn it off there, then check again."
                                      : "\(apps.joined(separator: ", ")) is using these shortcuts.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        if !apps.isEmpty {
                            Button("Quit \(apps.joined(separator: ", "))") { state.quitConflictingApps() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Check again") { state.checkShortcuts() }
                    }
                }
            }
            .frame(maxWidth: 380)
        }
        .onAppear { state.checkShortcuts() }
    }

    private var preferences: some View {
        StepContent(symbol: "slider.horizontal.3", tint: .orange, title: "A few preferences",
                    text: "You can change these any time from Settings in the menu bar.") {
            Form {
                Toggle("Open Screenme at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Toggle("Copy every capture to the clipboard", isOn: $state.copyAfterCapture)
                LabeledContent("Save to") {
                    Button(state.saveDirectory.lastPathComponent) { state.chooseSaveDirectory() }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 400, maxHeight: 170)
        }
    }

    private var ready: some View {
        StepContent(symbol: "checkmark.circle.fill", tint: .green, title: "You're set",
                    text: "Press ⌘⇧1 and drag to capture an area, or click a window. The capture lands bottom-left: drag it anywhere, or hover for Copy and Save.")
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= state.onboardingStep ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == state.onboardingStep ? 24 : 8, height: 8)
            }
        }
        .animation(.snappy, value: state.onboardingStep)
    }

    private var footer: some View {
        HStack {
            if state.onboardingStep > 0 && state.onboardingStep < steps.count - 1 {
                Button("Back") { state.onboardingStep -= 1 }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if state.onboardingStep < steps.count - 1 {
                Button(state.onboardingStep == 0 ? "Get started" : "Continue") { state.onboardingStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            } else {
                Button("Start using Screenme") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(24)
    }

    private var canContinue: Bool {
        switch state.onboardingStep {
        case 1: state.screenRecordingGranted
        case 2: state.shortcutsRegistered
        default: true
        }
    }
}

private struct StepContent<Extra: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var extra: () -> Extra

    init(symbol: String, tint: Color, title: String, text: String, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.text = text
        self.extra = extra
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(tint)
                .frame(height: 56)
            Text(title).font(.title.weight(.semibold))
            Text(text)
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra().padding(.top, 8)
        }
    }
}

struct StatusBadge: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? .green : .red)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((ok ? Color.green : Color.red).opacity(0.12), in: Capsule())
    }
}

struct ShortcutRow: View {
    let keys: String
    let label: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(label)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}
