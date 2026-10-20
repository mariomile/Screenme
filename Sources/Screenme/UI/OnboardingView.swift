import AppKit
import SwiftUI

/// First-run setup. The step is saved in `Pref.onboardingStep`, so a relaunch (needed after turning on
/// Screen Recording) resumes where the user was.
@MainActor
enum OnboardingWindow {
    static let stepCount = 6

    static func show() {
        placeStep()
        WindowPresenter.shared.show("onboarding", title: "Welcome to Screenme", size: CGSize(width: 700, height: 580),
                                    style: [.titled, .closable, .fullSizeContentView]) {
            OnboardingView()
        }
    }

    /// Before setup is done, resume the saved step (never past a missing Screen Recording grant).
    /// After setup, jump to the first step that needs attention.
    private static func placeStep() {
        AppState.shared.refresh()
        SystemShortcuts.shared.refresh()
        var step = Prefs[Pref.onboardingStep]
        if Prefs[Pref.onboardingDone] {
            if !AppState.shared.screenRecordingGranted {
                step = 1
            } else if SystemShortcuts.shared.macOSOwnsScreenshotShortcuts || !HotKeyCenter.shared.conflicts.isEmpty {
                step = 2
            } else {
                step = 0
            }
        } else if !AppState.shared.screenRecordingGranted && step > 1 {
            step = 1
        }
        Prefs[Pref.onboardingStep] = min(max(step, 0), stepCount - 1)
    }
}

struct OnboardingView: View {
    @AppStorage(Pref.onboardingStep.name) private var storedStep = Pref.onboardingStep.defaultValue
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var permissions = PermissionsModel.shared
    @State private var forward = true

    private var step: Int { min(max(storedStep, 0), OnboardingWindow.stepCount - 1) }
    private var isLast: Bool { step == OnboardingWindow.stepCount - 1 }

    private var canContinue: Bool {
        step == 1 ? state.screenRecordingGranted : true
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get Started"
        case 3: (permissions.microphone == .granted || permissions.camera == .granted || permissions.accessibility) ? "Continue" : "Skip for Now"
        case OnboardingWindow.stepCount - 1: "Start Using Screenme"
        default: "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 700, height: 580)
        .background(background)
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(0.14), .clear], center: .top, startRadius: 20, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ScreenRecordingStep()
        case 2: ShortcutsStep()
        case 3: OptionalPermissionsStep()
        case 4: PreferencesStep()
        default: DoneStep()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { go(step - 1) }
                .opacity(step == 0 ? 0 : 1)
                .disabled(step == 0)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<OnboardingWindow.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Color.accentColor : Color.primary.opacity(index < step ? 0.35 : 0.15))
                        .frame(width: index == step ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.2), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(OnboardingWindow.stepCount)")
            Spacer()
            Button(primaryTitle) {
                if isLast { finish() } else { go(step + 1) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func go(_ target: Int) {
        let clamped = min(max(target, 0), OnboardingWindow.stepCount - 1)
        forward = clamped > step
        withAnimation(.spring(duration: 0.45, bounce: 0.1)) { storedStep = clamped }
    }

    private func finish() {
        Prefs[Pref.onboardingDone] = true
        Prefs[Pref.onboardingStep] = 0
        WindowPresenter.shared.close("onboarding")
    }
}

// MARK: - Shared page layout

private struct StepPage<Content: View>: View {
    var symbol: String?
    var color: Color = .accentColor
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            if let symbol {
                SymbolTile(symbol: symbol, color: color, size: 60)
                    .shadow(color: color.opacity(0.35), radius: 10, y: 4)
            }
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            content
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .padding(.top, 48)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A rounded panel that holds a group of rows.
private struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - 0 Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            Text("Welcome to Screenme")
                .font(.system(size: 30, weight: .bold))
            Text("A fast, native way to capture your screen. Set it up in a minute.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            GroupCard {
                feature("camera.viewfinder", .blue, "Capture anything", "Areas, windows, full screens and scrolling pages.")
                feature("record.circle.fill", .red, "Record and share", "Screen recordings with audio, trimmed or exported as GIF.")
                feature("text.viewfinder", .teal, "Copy text from anywhere", "On-device text recognition and QR codes.")
            }
            .padding(.top, 8)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - 1 Screen Recording

private struct ScreenRecordingStep: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        StepPage(symbol: "rectangle.dashed.badge.record", color: .blue,
                 title: "Allow Screen Recording",
                 subtitle: "macOS asks for this before any app can capture the screen. Screenme never sends your screen anywhere.") {
            if state.screenRecordingGranted {
                GroupCard {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording is on").font(.system(size: 15, weight: .semibold))
                            Text("You can continue.").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                GroupCard {
                    instruction(1, "Click Open System Settings.")
                    instruction(2, "Turn on Screenme under Screen & System Audio Recording.")
                    instruction(3, "Come back here and click Relaunch.")
                }
                HStack(spacing: 10) {
                    Button("Open System Settings") { state.requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("I turned it on: Relaunch") { state.relaunch() }
                }
                .controlSize(.large)
                Text("macOS applies the new permission only to a fresh launch, so Screenme restarts and brings you back here.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: state.screenRecordingGranted)
        .polling(every: 0.8) { PermissionsModel.shared.refresh() }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.system(size: 13.5))
            Spacer()
        }
    }
}

// MARK: - 2 Shortcuts

private struct ShortcutsStep: View {
    @ObservedObject private var system = SystemShortcuts.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    private let actions: [ShortcutAction] = [.allInOne, .captureText, .captureFullscreen, .captureArea, .recordScreen]

    var body: some View {
        StepPage(symbol: "command", color: .orange,
                 title: "Your screenshot shortcuts",
                 subtitle: "Screenme replaces the macOS screenshot shortcuts, so ⇧⌘3, ⇧⌘4 and ⇧⌘5 open Screenme instead. You can change any of them later in Settings.") {
            GroupCard {
                ForEach(actions) { action in row(action) }
            }

            if system.macOSOwnsScreenshotShortcuts {
                GroupCard {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("macOS still uses ⇧⌘3, ⇧⌘4 and ⇧⌘5.").font(.system(size: 13.5, weight: .medium))
                        Spacer()
                    }
                    Button("Use Screenme for ⇧⌘3, ⇧⌘4, ⇧⌘5") { system.takeOver() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 8) {
                    StatusLabel(text: "The macOS screenshot shortcuts are off", tone: .good)
                    Button("Restore") { system.restore() }.buttonStyle(.link)
                }
            }

            RivalAppsBlock()
                .frame(maxWidth: 520)
        }
        .polling(every: 1) { SystemShortcuts.shared.refreshAndSync() }
    }

    private func shortWarning(_ status: ShortcutStatus) -> String {
        if case .usedByMacOS = status { return "macOS uses it" }
        return "Another app uses it"
    }

    private func row(_ action: ShortcutAction) -> some View {
        let combo = ShortcutStore.combo(for: action)
        let status = ShortcutStatus.of(action, combo: combo)
        return HStack(spacing: 10) {
            Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(action.title).font(.system(size: 13.5))
            Spacer()
            if status.isWarning {
                Text(shortWarning(status)).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            if let combo { KeyCaps(combo: combo, size: 11) }
            Image(systemName: status == .ok ? "checkmark.circle.fill" : (status.isWarning ? "exclamationmark.triangle.fill" : "circle.dashed"))
                .foregroundStyle(status == .ok ? Color.green : (status.isWarning ? Color.orange : Color.secondary))
                .frame(width: 18)
        }
    }
}

// MARK: - 3 Optional permissions

private struct OptionalPermissionsStep: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @State private var skipped: Set<String> = []

    var body: some View {
        StepPage(symbol: "lock.open.fill", color: .green,
                 title: "Optional permissions",
                 subtitle: "Only some features need these. Allow what you plan to use, skip the rest. You can change them anytime in Settings.") {
            GroupCard {
                row(id: "mic", symbol: "mic.fill", color: .red, title: "Microphone", detail: "Record your voice in screen recordings.",
                    granted: permissions.microphone == .granted, allow: { permissions.requestMicrophone() })
                Divider()
                row(id: "cam", symbol: "camera.fill", color: .gray, title: "Camera", detail: "Show your webcam in recordings.",
                    granted: permissions.camera == .granted, allow: { permissions.requestCamera() })
                Divider()
                row(id: "ax", symbol: "accessibility", color: .indigo, title: "Accessibility", detail: "Show keystrokes and scroll automatically for scrolling capture.",
                    granted: permissions.accessibility, allow: { permissions.requestAccessibility() })
            }
        }
        .polling(every: 1) { PermissionsModel.shared.refresh() }
    }

    private func row(id: String, symbol: String, color: Color, title: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                StatusLabel(text: "Allowed", tone: .good)
            } else if skipped.contains(id) {
                HStack(spacing: 8) {
                    Text("Skipped").font(.callout).foregroundStyle(.secondary)
                    Button("Allow", action: allow).buttonStyle(.link)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Not Now") { withAnimation(.easeOut(duration: 0.15)) { _ = skipped.insert(id) } }
                    Button("Allow", action: allow).buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - 4 Preferences

private struct PreferencesStep: View {
    @ObservedObject private var state = AppState.shared
    @AppStorage(Pref.saveDirectory.name) private var saveDirectory = Pref.saveDirectory.defaultValue

    var body: some View {
        StepPage(symbol: "slider.horizontal.3", color: .purple,
                 title: "Make it yours",
                 subtitle: "What should happen after you take a screenshot? These are all editable in Settings.") {
            Form {
                Section {
                    Toggle("Launch Screenme at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                }
                Section("After a screenshot") {
                    PrefToggle("Show Quick Access", Pref.afterShotQuickAccess)
                    PrefToggle("Copy to clipboard", Pref.afterShotCopy)
                    PrefToggle("Save to folder", Pref.afterShotSave)
                    PrefToggle("Open in editor", Pref.afterShotOpenEditor)
                }
                Section("Save folder") {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { state.chooseSaveDirectory() }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 540)
        }
        .padding(.top, -8)
    }
}

// MARK: - 5 Done

private struct DoneStep: View {
    @ObservedObject private var system = SystemShortcuts.shared
    @State private var appeared = false

    private var combo: KeyCombo? { ShortcutStore.combo(for: .captureArea) }

    var body: some View {
        StepPage(symbol: nil,
                 title: "You are all set",
                 subtitle: "Screenme lives in your menu bar. Take your first capture now.") {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.15)).frame(width: 96, height: 96)
                        .scaleEffect(appeared ? 1 : 0.6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.green)
                        .scaleEffect(appeared ? 1 : 0.3)
                }
                if let combo {
                    VStack(spacing: 8) {
                        Text("Press \(combo.display) to try it").font(.system(size: 16, weight: .semibold))
                        KeyCaps(combo: combo, size: 18)
                    }
                    if system.macOSShortcut(using: combo) != nil {
                        VStack(spacing: 8) {
                            Text("macOS still owns this shortcut. Take it over in Settings, or use the Screenme icon in the menu bar.")
                                .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420)
                            Button("Open Shortcuts Settings") { SettingsWindow.show(tab: .shortcuts) }
                        }
                    }
                } else {
                    Text("Use the Screenme icon in the menu bar to start a capture.").foregroundStyle(.secondary)
                }
                Button("Open Settings") { SettingsWindow.show() }
                    .buttonStyle(.link)
            }
        }
        .onAppear {
            Prefs[Pref.onboardingDone] = true
            withAnimation(.spring(duration: 0.6, bounce: 0.35).delay(0.1)) { appeared = true }
        }
        .polling(every: 1.5) { SystemShortcuts.shared.refreshAndSync() }
    }
}
