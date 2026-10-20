import AppKit
import SwiftUI

// MARK: - 0 Welcome

struct WelcomeStep: View {
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

struct ScreenRecordingStep: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        StepPage(symbol: "rectangle.dashed.badge.record", color: .blue,
                 title: "Allow Screen Recording",
                 subtitle: "macOS asks for this before any app can capture the screen. Screenme never sends your screen anywhere.") {
            if permissions.isGranted(.screenRecording) {
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
                    Button("Open System Settings") { Permission.screenRecording.request() }
                        .buttonStyle(.borderedProminent)
                    Button("I turned it on: Relaunch") { state.relaunch() }
                }
                .controlSize(.large)
                Text("macOS applies the new permission only to a fresh launch, so Screenme restarts and brings you back here.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: permissions.isGranted(.screenRecording))
        .polling(every: 0.8) { Permissions.shared.refresh() }
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

struct ShortcutsStep: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    private let actions: [ShortcutAction] = [.allInOne, .captureText, .captureFullscreen, .captureArea, .recordScreen]

    var body: some View {
        StepPage(symbol: "command", color: .orange,
                 title: "Your screenshot shortcuts",
                 subtitle: "Screenme replaces the macOS screenshot shortcuts, so ⇧⌘3, ⇧⌘4 and ⇧⌘5 open Screenme instead. You can change any of them later in Settings.") {
            GroupCard {
                ForEach(actions) { action in row(action) }
            }

            GroupCard {
                MacOSShortcutsBlock(listsEach: false)
            }

            RivalAppsBlock()
                .frame(maxWidth: 520)
        }
        .onAppear { shortcuts.refresh() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let status = shortcuts.status(for: action)
        return HStack(spacing: 10) {
            Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(action.title).font(.system(size: 13.5))
            Spacer()
            if let combo = shortcuts.combo(for: action) { KeyCaps(combo: combo, size: 11) }
            StatusLabel(text: status.shortText, tone: status.tone, font: .caption)
                .lineLimit(1)
        }
    }
}

// MARK: - 3 Optional permissions

struct OptionalPermissionsStep: View {
    var body: some View {
        StepPage(symbol: "lock.open.fill", color: .green,
                 title: "Optional permissions",
                 subtitle: "Only some features need these. Allow what you plan to use, skip the rest. You can change them anytime in Settings.") {
            GroupCard {
                PermissionRow(permission: .microphone)
                Divider()
                PermissionRow(permission: .camera)
                Divider()
                PermissionRow(permission: .accessibility)
            }
        }
        .polling(every: 1) { Permissions.shared.refresh() }
    }
}

// MARK: - 4 Preferences

struct PreferencesStep: View {
    var body: some View {
        StepPage(symbol: "slider.horizontal.3", color: .purple,
                 title: "Make it yours",
                 subtitle: "What should happen after you take a screenshot? These are all editable in Settings.") {
            Form {
                Section {
                    LaunchAtLoginToggle()
                }
                AfterCaptureSection(title: "After a screenshot", showsFooter: false)
                Section {
                    SaveFolderRow()
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

struct DoneStep: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared
    @State private var appeared = false

    private var combo: KeyCombo? { shortcuts.combo(for: .captureArea) }

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
                    if shortcuts.system.macOSShortcut(using: combo) != nil {
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
    }
}
