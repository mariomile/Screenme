import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

// MARK: - Window

@MainActor
enum SettingsWindow {
    static func show() {
        let window = WindowPresenter.shared.show("settings", title: "Screenme Settings", size: CGSize(width: 800, height: 580),
                                                 style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) {
            SettingsView()
        }
        window.contentMinSize = CGSize(width: 720, height: 480)
    }

    static func show(tab: SettingsTab) {
        Prefs[Pref.settingsTab] = tab
        show()
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, screenshots, quickAccess, recording, text, shortcuts, permissions, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .quickAccess: "Quick Access"
        case .recording: "Recording"
        case .text: "Text Recognition"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .screenshots: "camera.viewfinder"
        case .quickAccess: "rectangle.on.rectangle"
        case .recording: "record.circle.fill"
        case .text: "text.viewfinder"
        case .shortcuts: "command"
        case .permissions: "lock.shield.fill"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .screenshots: .blue
        case .quickAccess: .indigo
        case .recording: .red
        case .text: .teal
        case .shortcuts: .orange
        case .permissions: .green
        case .history: .purple
        case .about: .gray
        }
    }
}

struct SettingsView: View {
    @AppStorage(Pref.settingsTab.name) private var tab = Pref.settingsTab.defaultValue

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
                .background(SidebarMaterial().ignoresSafeArea())
            Divider().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                pane
                    .id(tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .animation(.easeOut(duration: 0.15), value: tab)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 9) {
                        SymbolTile(symbol: item.symbol, color: item.color, size: 22)
                        Text(item.title).font(.system(size: 13.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .foregroundStyle(item == tab ? Color.white : Color.primary)
                    .background(item == tab ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = SettingsTab.allCases
            guard let index = all.firstIndex(of: tab) else { return }
            switch direction {
            case .up: tab = all[max(index - 1, 0)]
            case .down: tab = all[min(index + 1, all.count - 1)]
            default: break
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane()
        case .screenshots: ScreenshotsPane()
        case .quickAccess: QuickAccessPane()
        case .recording: RecordingPane()
        case .text: TextRecognitionPane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .history: HistoryPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Bound controls

/// A switch bound to a Bool preference.
struct PrefToggle: View {
    let title: String
    var detail: String?
    @AppStorage private var value: Bool

    init(_ title: String, _ key: PrefKey<Bool>, detail: String? = nil) {
        self.title = title
        self.detail = detail
        _value = AppStorage(wrappedValue: key.defaultValue, key.name)
    }

    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A pop-up bound to an Int preference.
struct PrefIntPicker: View {
    let title: String
    let options: [(label: String, value: Int)]
    @AppStorage private var value: Int

    init(_ title: String, _ key: PrefKey<Int>, options: [(label: String, value: Int)]) {
        self.title = title
        self.options = options
        _value = AppStorage(wrappedValue: key.defaultValue, key.name)
    }

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var state = AppState.shared
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                Toggle("Launch Screenme at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: {
                        state.setLaunchAtLogin($0)
                        loginStatus = SMAppService.mainApp.status
                    }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Label("Approve Screenme in Login Items to finish.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: {
                Text("Startup")
            }

            Section("Feedback") {
                PrefToggle("Play sounds", Pref.playSounds, detail: "A shutter sound after each screenshot.")
            }

            Section {
                LabeledContent("Menu bar") {
                    Text("Screenme lives in the menu bar").foregroundStyle(.secondary)
                }
                LabeledContent("Welcome guide") {
                    Button("Show Welcome Guide…") { OnboardingWindow.show() }
                }
                LabeledContent("Quit") {
                    Button("Quit Screenme") { NSApp.terminate(nil) }
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Click the menu bar icon to capture, record or open History. Closing this window keeps Screenme running.")
            }
        }
        .formStyle(.grouped)
        .polling(every: 2) {
            state.refresh()
            loginStatus = SMAppService.mainApp.status
        }
    }
}

// MARK: - Screenshots

private struct ScreenshotsPane: View {
    @AppStorage(Pref.imageFormat.name) private var format = Pref.imageFormat.defaultValue
    @AppStorage(Pref.jpegQuality.name) private var quality = Pref.jpegQuality.defaultValue
    @AppStorage(Pref.fileNamePrefix.name) private var prefix = Pref.fileNamePrefix.defaultValue
    @AppStorage(Pref.saveDirectory.name) private var saveDirectory = Pref.saveDirectory.defaultValue
    @ObservedObject private var state = AppState.shared

    private var exampleName: String {
        let name = prefix.isEmpty ? "Screenme" : prefix
        return "\(name) 2026-10-20 at 10.41.00.\(format.fileExtension)"
    }

    var body: some View {
        Form {
            Section {
                PrefToggle("Show Quick Access", Pref.afterShotQuickAccess)
                PrefToggle("Copy to clipboard", Pref.afterShotCopy)
                PrefToggle("Save to folder", Pref.afterShotSave)
                PrefToggle("Open in editor", Pref.afterShotOpenEditor)
            } header: {
                Text("After capture")
            } footer: {
                Text("Pick any combination. With Open in editor on, the editor opens instead of Quick Access.")
            }

            Section("File") {
                Picker("Format", selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if format == .jpg {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.5...1, step: 0.05).frame(width: 180)
                            Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                PrefToggle("Save at Retina resolution", Pref.retinaResolution, detail: "Turn off to save at 1x, which makes smaller files.")
                LabeledContent("File name prefix") {
                    TextField("File name prefix", text: $prefix, prompt: Text("Screenme")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LabeledContent("Example") {
                    Text(exampleName).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Save folder") {
                    HStack {
                        Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { state.chooseSaveDirectory() }
                    }
                }
            }

            Section("Capture") {
                PrefToggle("Show cursor", Pref.showCursorInShots)
                PrefToggle("Capture window shadow", Pref.windowShadow)
                PrefToggle("Freeze screen while selecting", Pref.freezeScreen)
                PrefToggle("Show crosshair", Pref.showCrosshair)
                PrefToggle("Show magnifier", Pref.showMagnifier)
                PrefIntPicker("Self-timer", Pref.selfTimerSeconds, options: [("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15)])
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quick Access

private struct QuickAccessPane: View {
    @AppStorage(Pref.quickAccessPosition.name) private var position = Pref.quickAccessPosition.defaultValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    Spacer()
                    positionChoice("Bottom left", value: .bottomLeft)
                    positionChoice("Bottom right", value: .bottomRight)
                    Spacer()
                }
                .padding(.vertical, 6)
            } header: {
                Text("Position")
            } footer: {
                Text("Cards appear on the screen where your mouse is, and stack upward.")
            }

            Section {
                PrefIntPicker("Close automatically", Pref.quickAccessAutoClose,
                              options: [("Never", 0), ("After 3 seconds", 3), ("After 5 seconds", 5), ("After 10 seconds", 10), ("After 15 seconds", 15), ("After 30 seconds", 30)])
            } header: {
                Text("Behavior")
            } footer: {
                Text("The timer pauses while you hover a card. Drag a card into any app to use it, or swipe it toward the screen edge to dismiss.")
            }
        }
        .formStyle(.grouped)
    }

    private func positionChoice(_ title: String, value: QuickAccessPosition) -> some View {
        let selected = position == value
        let right = value == .bottomRight
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { position = value }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: right ? .bottomTrailing : .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 26, height: 18)
                        .padding(7)
                }
                .frame(width: 120, height: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
                )
                Text(title).font(.callout).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Recording

private struct MicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

private struct RecordingPane: View {
    @AppStorage(Pref.recordingMicrophone.name) private var microphoneOn = Pref.recordingMicrophone.defaultValue
    @AppStorage(Pref.recordingMicrophoneID.name) private var microphoneID = Pref.recordingMicrophoneID.defaultValue
    @AppStorage(Pref.recordingShowKeystrokes.name) private var keystrokes = Pref.recordingShowKeystrokes.defaultValue
    @AppStorage(Pref.recordingWebcam.name) private var webcam = Pref.recordingWebcam.defaultValue
    @AppStorage(Pref.recordingQuality.name) private var quality = Pref.recordingQuality.defaultValue
    @ObservedObject private var permissions = PermissionsModel.shared
    @State private var devices: [MicrophoneDevice] = []

    var body: some View {
        Form {
            Section {
                PrefToggle("Show Quick Access", Pref.afterRecordingQuickAccess)
                PrefToggle("Copy file to clipboard", Pref.afterRecordingCopy)
                PrefToggle("Save to folder", Pref.afterRecordingSave)
            } header: {
                Text("After recording")
            }

            Section("Video") {
                PrefIntPicker("Frame rate", Pref.recordingFPS, options: [("30 fps", 30), ("60 fps", 60)])
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                PrefToggle("Show cursor", Pref.recordingShowCursor)
                PrefToggle("Highlight clicks", Pref.recordingHighlightClicks)
                Toggle("Show keystrokes", isOn: $keystrokes)
                if keystrokes && !permissions.accessibility {
                    permissionHint("Keystrokes need Accessibility access.", button: "Grant") { permissions.requestAccessibility() }
                }
                PrefIntPicker("Countdown", Pref.recordingCountdown, options: [("Off", 0), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10)])
                PrefToggle("Hide desktop icons while recording", Pref.recordingHideDesktopIcons)
            }

            Section("Audio and camera") {
                Toggle("Record microphone", isOn: $microphoneOn)
                if microphoneOn {
                    Picker("Microphone", selection: $microphoneID) {
                        Text("System default").tag("")
                        ForEach(devices) { Text($0.name).tag($0.id) }
                        if !microphoneID.isEmpty && !devices.contains(where: { $0.id == microphoneID }) {
                            Text("Unavailable device").tag(microphoneID)
                        }
                    }
                    if permissions.microphone != .granted {
                        permissionHint("Microphone access is off.", button: permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                            permissions.requestMicrophone()
                        }
                    }
                }
                PrefToggle("Record system audio", Pref.recordingSystemAudio)
                Toggle("Show webcam", isOn: $webcam)
                if webcam && permissions.camera != .granted {
                    permissionHint("Camera access is off.", button: permissions.camera == .notDetermined ? "Allow" : "Open Settings") {
                        permissions.requestCamera()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .polling(every: 2) {
            permissions.refresh()
            devices = MicrophoneDevice.available()
        }
    }

    private func permissionHint(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            Spacer()
            Button(button, action: action)
        }
    }
}

// MARK: - Text recognition

private struct TextRecognitionPane: View {
    @State private var combo = ShortcutStore.combo(for: .captureText)

    var body: some View {
        Form {
            Section {
                PrefToggle("Keep line breaks", Pref.ocrKeepLineBreaks, detail: "Off joins the lines of a paragraph into one.")
                PrefToggle("Detect QR codes", Pref.ocrDetectQR, detail: "Copies the link or text a QR code holds.")
            } footer: {
                HStack(spacing: 6) {
                    Text("Select an area to copy its text.")
                    if let combo { Text("Shortcut:"); KeyCaps(combo: combo, size: 10) }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .shortcutsChanged)) { _ in
            combo = ShortcutStore.combo(for: .captureText)
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        Form {
            Section {
                PermissionRow(symbol: "rectangle.dashed.badge.record", color: .blue, title: "Screen Recording",
                              detail: "Required to take screenshots and record the screen.",
                              granted: state.screenRecordingGranted, primary: { state.requestScreenRecording() },
                              openSettings: { permissions.openSettings(.screenRecording) })
                PermissionRow(symbol: "mic.fill", color: .red, title: "Microphone",
                              detail: "Records your voice in screen recordings.",
                              granted: permissions.microphone == .granted,
                              deniedHint: permissions.microphone == .notDetermined ? "Not asked yet" : "Not allowed",
                              primary: { permissions.requestMicrophone() },
                              openSettings: { permissions.openSettings(.microphone) },
                              showOpenSettings: permissions.microphone != .notDetermined)
                PermissionRow(symbol: "camera.fill", color: .gray, title: "Camera",
                              detail: "Shows your webcam in screen recordings.",
                              granted: permissions.camera == .granted,
                              deniedHint: permissions.camera == .notDetermined ? "Not asked yet" : "Not allowed",
                              primary: { permissions.requestCamera() },
                              openSettings: { permissions.openSettings(.camera) },
                              showOpenSettings: permissions.camera != .notDetermined)
                PermissionRow(symbol: "accessibility", color: .indigo, title: "Accessibility",
                              detail: "Shows keystrokes in recordings and drives scrolling capture.",
                              granted: permissions.accessibility, primary: { permissions.requestAccessibility() },
                              openSettings: { permissions.openSettings(.accessibility) })
            } footer: {
                Text("Permissions are managed by macOS. Screenme only asks for what a feature needs.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Relaunch Screenme")
                        Text(state.screenRecordingGranted
                             ? "Use this if captures still fail after changing a permission."
                             : "After turning Screen Recording on, relaunch so macOS applies it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.screenRecordingGranted {
                        Button("Relaunch") { state.relaunch() }
                    } else {
                        Button("Relaunch") { state.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .polling(every: 1) { permissions.refresh() }
    }
}

// MARK: - History

private struct HistoryPane: View {
    var body: some View {
        Form {
            Section {
                PrefIntPicker("Keep captures for", Pref.historyDays,
                              options: [("1 day", 1), ("7 days", 7), ("14 days", 14), ("30 days", 30), ("90 days", 90), ("1 year", 365), ("Forever", 0)])
            } footer: {
                Text("Captures older than this are removed from History. Files you saved to your folder are never touched.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Screenme").font(.system(size: 26, weight: .bold))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            Text("Screenshots, screen recordings and text capture for macOS, from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/mariomile/Screenme")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.bordered)
                Button("Welcome Guide") { OnboardingWindow.show() }
            }
            Text("Open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The translucent sidebar background used by System Settings.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
