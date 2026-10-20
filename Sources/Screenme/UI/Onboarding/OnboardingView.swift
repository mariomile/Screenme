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
        Permissions.shared.refresh()
        let shortcuts = ShortcutsModel.shared
        shortcuts.refresh()
        let screenRecording = Permission.screenRecording.isGranted
        var step = Prefs[Pref.onboardingStep]
        if Prefs[Pref.onboardingDone] {
            if !screenRecording {
                step = 1
            } else if shortcuts.system.macOSOwnsScreenshotShortcuts || !HotKeyCenter.shared.conflicts.isEmpty {
                step = 2
            } else {
                step = 0
            }
        } else if !screenRecording && step > 1 {
            step = 1
        }
        Prefs[Pref.onboardingStep] = min(max(step, 0), stepCount - 1)
    }
}

struct OnboardingView: View {
    @AppStorage(Pref.onboardingStep.name) private var storedStep = Pref.onboardingStep.defaultValue
    @ObservedObject private var permissions = Permissions.shared
    @State private var forward = true

    private var step: Int { min(max(storedStep, 0), OnboardingWindow.stepCount - 1) }
    private var isLast: Bool { step == OnboardingWindow.stepCount - 1 }

    private var canContinue: Bool {
        step == 1 ? permissions.isGranted(.screenRecording) : true
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get Started"
        case 3: [Permission.microphone, .camera, .accessibility].contains(where: permissions.isGranted) ? "Continue" : "Skip for Now"
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

struct StepPage<Content: View>: View {
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
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
