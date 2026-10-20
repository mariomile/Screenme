import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// The compact bar shown next to the area before recording starts, with the camera preview and the dimming.
/// The user edits a copy of the recording settings; every change is saved for next time.
@MainActor
final class PreRecordUI: ObservableObject {
    @Published var settings = RecordingSettings.saved {
        didSet {
            settings.save()
            if settings.webcam != oldValue.webcam { setWebcam(settings.webcam) }
            if let webcam, webcam.size != settings.webcamSize { webcam.setSize(settings.webcamSize) }
        }
    }
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var cameras: [AVCaptureDevice] = []

    private let target: CaptureTarget
    private var dimmer: AreaDimmer?
    private var barPanel: FloatingPanel?
    private var keyMonitor: Any?
    private var escape: TemporaryHotKey?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// The camera preview. The recording takes it over.
    private var webcam: WebcamBubble?

    init(target: CaptureTarget) {
        self.target = target
        refreshDevices()
        // A permission revoked since last time must not leave the toggle on.
        if settings.microphone, !Permission.microphone.isGranted { settings.microphone = false }
        if settings.webcam, !Permission.camera.isGranted { settings.webcam = false }
    }

    /// Shows the bar until the user records or cancels, then removes it. Returns the settings to record with and
    /// the camera preview, which the caller now owns; nil when the user cancelled.
    func run() async -> (RecordingSettings, WebcamBubble?)? {
        let frame = target.cocoaFrame
        let screen = Placement.screen(for: target)

        let dimmer = AreaDimmer(area: frame, screen: screen)
        dimmer.show()
        self.dimmer = dimmer

        let view = NSHostingView(rootView: PreRecordBar(model: self,
                                                        record: { [weak self] in self?.finish(record: true) },
                                                        cancel: { [weak self] in self?.finish(record: false) }))
        let size = view.fittingSize
        let panel = FloatingPanel(frame: Placement.barFrame(size: size, near: frame, on: screen), level: .popUpMenu, canBeKey: true)
        panel.isMovableByWindowBackground = true
        panel.contentView = view
        panel.present(makeKey: true)
        barPanel = panel
        FocusKeeper.activateSelf()

        installKeyMonitors()
        setWebcam(settings.webcam)

        let record = await withCheckedContinuation { continuation = $0 }
        removeKeyMonitors()
        barPanel?.dismiss()
        barPanel = nil
        self.dimmer?.close()
        self.dimmer = nil

        let webcam = self.webcam
        self.webcam = nil
        webcam?.onResize = nil
        guard record else {
            webcam?.close()
            return nil
        }
        return (settings, webcam)
    }

    func refreshDevices() {
        microphones = InputDevices.microphones()
        cameras = InputDevices.cameras()
    }

    var microphoneName: String {
        microphones.first { $0.uniqueID == settings.microphoneID }?.localizedName ?? "System Default"
    }

    func toggleMicrophone() {
        if settings.microphone {
            settings.microphone = false
            return
        }
        Task {
            if await Permission.microphone.ensure() { settings.microphone = true }
        }
    }

    func toggleWebcam() {
        if settings.webcam {
            settings.webcam = false
            return
        }
        Task {
            if await Permission.camera.ensure() { settings.webcam = true }
        }
    }

    func selectMicrophone(_ id: String) {
        settings.microphoneID = id
        if !settings.microphone { toggleMicrophone() }
    }

    func setKeystrokes(_ on: Bool) {
        settings.showKeystrokes = on
        if on, !Permission.accessibility.isGranted { Permission.accessibility.request() }
    }

    private func finish(record: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: record)
    }

    /// Opens or closes the camera preview while the bar is up.
    private func setWebcam(_ on: Bool) {
        guard barPanel != nil else { return }
        if on, webcam == nil {
            guard Permission.camera.isGranted else { return }
            if let bubble = WebcamBubble(near: target.cocoaFrame, size: settings.webcamSize, deviceID: settings.webcamID) {
                bubble.onResize = { [weak self] size in self?.settings.webcamSize = size }
                bubble.show()
                webcam = bubble
            } else {
                settings.webcam = false
                Toast.show("No camera found", symbol: "video.slash.fill")
            }
        } else if !on {
            webcam?.close()
            webcam = nil
        }
    }

    /// Return records while the bar has focus. Esc cancels from anywhere, even after a click into another app.
    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 36 || event.keyCode == 76 else { return event }
            finish(record: true)
            return nil
        }
        escape = HotKeyCenter.shared.registerTemporary(keyCode: UInt32(kVK_Escape)) { [weak self] in self?.finish(record: false) }
    }

    private func removeKeyMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        HotKeyCenter.shared.unregisterTemporary(escape)
        escape = nil
    }
}

// MARK: - View

private struct PreRecordBar: View {
    @ObservedObject var model: PreRecordUI
    let record: () -> Void
    let cancel: () -> Void

    private var settings: RecordingSettings { model.settings }
    private var audioAvailable: Bool { settings.profile.capturesAudio }

    var body: some View {
        HStack(spacing: 4) {
            BarButton(symbol: "xmark", help: "Cancel (Esc)", action: cancel)
            divider
            FormatSwitch(format: $model.settings.format)
            divider
            HStack(spacing: 0) {
                BarButton(symbol: settings.microphone ? "mic.fill" : "mic.slash.fill", active: settings.microphone && audioAvailable,
                          help: "Microphone: \(settings.microphone ? model.microphoneName : "off")") { model.toggleMicrophone() }
                microphoneMenu
            }
            .opacity(audioAvailable ? 1 : 0.35)
            .disabled(!audioAvailable)
            BarButton(symbol: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", active: settings.systemAudio && audioAvailable,
                      help: "System audio") { model.settings.systemAudio.toggle() }
                .opacity(audioAvailable ? 1 : 0.35)
                .disabled(!audioAvailable)
            HStack(spacing: 0) {
                BarButton(symbol: settings.webcam ? "video.fill" : "video.slash.fill", active: settings.webcam,
                          help: "Camera") { model.toggleWebcam() }
                cameraMenu
            }
            optionsMenu
            divider
            RecordButton(action: record)
        }
        .padding(6)
        .background(VisualEffectBackground().clipShape(Capsule()))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onAppear { model.refreshDevices() }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private var microphoneMenu: some View {
        Menu {
            Picker("Microphone", selection: Binding(get: { settings.microphoneID }, set: { model.selectMicrophone($0) })) {
                Text("System Default").tag("")
                ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        } label: {
            ChevronLabel()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Choose microphone")
    }

    private var cameraMenu: some View {
        Menu {
            Picker("Size", selection: $model.settings.webcamSize) {
                ForEach(WebcamSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if !model.cameras.isEmpty {
                Divider()
                Picker("Camera", selection: $model.settings.webcamID) {
                    Text("Default Camera").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            ChevronLabel()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Camera size and device")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Cursor", isOn: $model.settings.showCursor)
            Toggle("Highlight Clicks", isOn: $model.settings.highlightClicks)
            Toggle("Show Keystrokes", isOn: Binding(get: { settings.showKeystrokes }, set: { model.setKeystrokes($0) }))
            if settings.showKeystrokes, !Permission.accessibility.isGranted {
                Text("Keystrokes need Accessibility access")
            }
            Divider()
            Toggle("Hide Desktop Icons", isOn: $model.settings.hideDesktopIcons)
            Picker("Countdown", selection: $model.settings.countdown) {
                Text("No Countdown").tag(0)
                Text("3 Seconds").tag(3)
                Text("5 Seconds").tag(5)
                Text("10 Seconds").tag(10)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Recording options")
    }
}

private struct ChevronLabel: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 14, height: 34)
            .contentShape(Rectangle())
    }
}

private struct FormatSwitch: View {
    @Binding var format: RecordingFormat

    var body: some View {
        HStack(spacing: 2) {
            segment("Video", .video)
            segment("GIF", .gif)
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func segment(_ title: String, _ value: RecordingFormat) -> some View {
        Button { withAnimation(.easeOut(duration: 0.14)) { format = value } } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(format == value ? 1 : 0.6))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(format == value ? 0.2 : 0)))
        }
        .buttonStyle(.plain)
    }
}

private struct RecordButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(.white).frame(width: 8, height: 8)
                Text("Record").font(.system(size: 13, weight: .semibold))
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(hovering ? 1 : 0.92)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start recording (Return)")
    }
}
