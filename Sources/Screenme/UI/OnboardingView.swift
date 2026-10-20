import SwiftUI

/// First-run setup. Stub: permission only; the full onboarding replaces this.
@MainActor
enum OnboardingWindow {
    static func show() {
        WindowPresenter.shared.show("onboarding", title: "Welcome to Screenme", size: CGSize(width: 520, height: 320)) {
            OnboardingStub(state: AppState.shared)
        }
    }
}

private struct OnboardingStub: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Screenme").font(.title.weight(.semibold))
            if state.screenRecordingGranted {
                Button("Done") {
                    Prefs[Pref.onboardingDone] = true
                    WindowPresenter.shared.close("onboarding")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Screen Recording") { state.requestScreenRecording() }.buttonStyle(.borderedProminent)
                Button("I turned it on: Relaunch") { state.relaunch() }
            }
        }
        .frame(width: 520, height: 320)
    }
}
