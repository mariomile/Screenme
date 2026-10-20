import AppKit
import AVFoundation
import Combine
import SwiftUI

/// What the user can change before pressing Record. Every change is written to the preferences.
@MainActor
final class RecorderOptions: ObservableObject {
    @Published var format = Prefs[Pref.recordingFormat] {
        didSet { Prefs[Pref.recordingFormat] = format }
    }
    @Published var microphone = Prefs[Pref.recordingMicrophone] {
        didSet { Prefs[Pref.recordingMicrophone] = microphone }
    }
    @Published var microphoneID = Prefs[Pref.recordingMicrophoneID] {
        didSet { Prefs[Pref.recordingMicrophoneID] = microphoneID }
    }
    @Published var systemAudio = Prefs[Pref.recordingSystemAudio] {
        didSet { Prefs[Pref.recordingSystemAudio] = systemAudio }
    }
    @Published var webcam = Prefs[Pref.recordingWebcam] {
        didSet { Prefs[Pref.recordingWebcam] = webcam }
    }
    @Published var webcamSize = Prefs[Pref.recordingWebcamSize] {
        didSet { Prefs[Pref.recordingWebcamSize] = webcamSize }
    }
    @Published var webcamID = Prefs[Pref.recordingWebcamID] {
        didSet { Prefs[Pref.recordingWebcamID] = webcamID }
    }
    @Published var showCursor = Prefs[Pref.recordingShowCursor] {
        didSet { Prefs[Pref.recordingShowCursor] = showCursor }
    }
    @Published var highlightClicks = Prefs[Pref.recordingHighlightClicks] {
        didSet { Prefs[Pref.recordingHighlightClicks] = highlightClicks }
    }
    @Published var showKeystrokes = Prefs[Pref.recordingShowKeystrokes] {
        didSet { Prefs[Pref.recordingShowKeystrokes] = showKeystrokes }
    }
    @Published var countdown = Prefs[Pref.recordingCountdown] {
        didSet { Prefs[Pref.recordingCountdown] = countdown }
    }
    @Published var hideDesktopIcons = Prefs[Pref.recordingHideDesktopIcons] {
        didSet { Prefs[Pref.recordingHideDesktopIcons] = hideDesktopIcons }
    }
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var cameras: [AVCaptureDevice] = []

    init() {
        refreshDevices()
        // A permission revoked since last time must not leave the toggle on.
        if microphone, !MediaAccess.isAuthorized(.audio) { microphone = false }
        if webcam, !MediaAccess.isAuthorized(.video) { webcam = false }
    }

    func refreshDevices() {
        microphones = InputDevices.microphones()
        cameras = InputDevices.cameras()
    }

    var microphoneName: String {
        microphones.first { $0.uniqueID == microphoneID }?.localizedName ?? "System Default"
    }

    func toggleMicrophone() {
        if microphone {
            microphone = false
            return
        }
        Task {
            if await MediaAccess.ensure(.audio) { microphone = true } else { MediaAccess.explainDenied(.audio) }
        }
    }

    func toggleWebcam() {
        if webcam {
            webcam = false
            return
        }
        Task {
            if await MediaAccess.ensure(.video) { webcam = true } else { MediaAccess.explainDenied(.video) }
        }
    }

    func selectMicrophone(_ id: String) {
        microphoneID = id
        if !microphone { toggleMicrophone() }
    }

    func setKeystrokes(_ on: Bool) {
        showKeystrokes = on
        if on, !Accessibility.trusted { Accessibility.prompt() }
    }
}

/// The compact bar shown next to the area before recording starts.
@MainActor
final class PreRecordUI {
    enum Decision { case record, cancel }

    let options = RecorderOptions()
    private let target: CaptureTarget
    private var dimmer: AreaDimmer?
    private var barPanel: FloatingPanel?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var continuation: CheckedContinuation<Decision, Never>?

    /// The camera preview. It outlives this object: the recording takes it over.
    private(set) var webcam: WebcamBubble?

    init(target: CaptureTarget) {
        self.target = target
    }

    func run() async -> Decision {
        let frame = target.cocoaFrame
        let screen = Placement.screen(for: target)

        let dimmer = AreaDimmer(area: frame, screen: screen)
        dimmer.show()
        self.dimmer = dimmer

        let view = NSHostingView(rootView: PreRecordBar(options: options,
                                                        record: { [weak self] in self?.finish(.record) },
                                                        cancel: { [weak self] in self?.finish(.cancel) }))
        let size = view.fittingSize
        let panel = FloatingPanel(frame: Placement.barFrame(size: size, near: frame, on: screen), level: .popUpMenu, canBeKey: true)
        panel.isMovableByWindowBackground = true
        panel.contentView = view
        panel.present(makeKey: true)
        barPanel = panel
        FocusKeeper.activateSelf()

        installKeyMonitors()
        options.$webcam
            .sink { [weak self] on in self?.setWebcam(on) }
            .store(in: &subscriptions)
        options.$webcamSize
            .sink { [weak self] size in
                guard let webcam = self?.webcam, webcam.size != size else { return }
                webcam.setSize(size)
            }
            .store(in: &subscriptions)

        let decision = await withCheckedContinuation { continuation = $0 }
        removeKeyMonitors()
        subscriptions.removeAll()
        return decision
    }

    /// Removes the bar and the dimming. The camera preview stays.
    func dismiss() {
        barPanel?.dismiss()
        barPanel = nil
        dimmer?.close()
        dimmer = nil
    }

    /// Hands the camera preview over to the recording.
    func takeWebcam() -> WebcamBubble? {
        defer { webcam = nil }
        return webcam
    }

    func closeWebcam() {
        webcam?.close()
        webcam = nil
    }

    private func finish(_ decision: Decision) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decision)
    }

    private func setWebcam(_ on: Bool) {
        if on, webcam == nil {
            guard MediaAccess.isAuthorized(.video) else { return }
            let bubble = WebcamBubble(near: target.cocoaFrame, size: options.webcamSize, deviceID: options.webcamID)
            if let bubble {
                bubble.show()
                webcam = bubble
            } else {
                options.webcam = false
                Toast.show("No camera found", symbol: "video.slash.fill")
            }
        } else if !on {
            closeWebcam()
        }
    }

    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 36, 76: finish(.record); return nil
            case 53: finish(.cancel); return nil
            default: return event
            }
        }
        if Accessibility.trusted {
            // Still works when the user clicked into another app while setting up.
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let code = event.keyCode
                MainActor.assumeIsolated {
                    if code == 36 || code == 76 { self?.finish(.record) } else if code == 53 { self?.finish(.cancel) }
                }
            }
        }
    }

    private func removeKeyMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        keyMonitor = nil
        globalKeyMonitor = nil
    }
}

// MARK: - View

private struct PreRecordBar: View {
    @ObservedObject var options: RecorderOptions
    let record: () -> Void
    let cancel: () -> Void

    private var audioAvailable: Bool { options.format == .video }

    var body: some View {
        HStack(spacing: 4) {
            BarButton(symbol: "xmark", help: "Cancel (Esc)", action: cancel)
            divider
            FormatSwitch(format: $options.format)
            divider
            HStack(spacing: 0) {
                BarButton(symbol: options.microphone ? "mic.fill" : "mic.slash.fill", active: options.microphone && audioAvailable,
                          help: "Microphone: \(options.microphone ? options.microphoneName : "off")") { options.toggleMicrophone() }
                microphoneMenu
            }
            .opacity(audioAvailable ? 1 : 0.35)
            .disabled(!audioAvailable)
            BarButton(symbol: options.systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", active: options.systemAudio && audioAvailable,
                      help: "System audio") { options.systemAudio.toggle() }
                .opacity(audioAvailable ? 1 : 0.35)
                .disabled(!audioAvailable)
            HStack(spacing: 0) {
                BarButton(symbol: options.webcam ? "video.fill" : "video.slash.fill", active: options.webcam,
                          help: "Camera") { options.toggleWebcam() }
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
        .onAppear { options.refreshDevices() }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private var microphoneMenu: some View {
        Menu {
            Picker("Microphone", selection: Binding(get: { options.microphoneID }, set: { options.selectMicrophone($0) })) {
                Text("System Default").tag("")
                ForEach(options.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
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
            Picker("Size", selection: $options.webcamSize) {
                ForEach(WebcamSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if !options.cameras.isEmpty {
                Divider()
                Picker("Camera", selection: $options.webcamID) {
                    Text("Default Camera").tag("")
                    ForEach(options.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
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
            Toggle("Show Cursor", isOn: $options.showCursor)
            Toggle("Highlight Clicks", isOn: $options.highlightClicks)
            Toggle("Show Keystrokes", isOn: Binding(get: { options.showKeystrokes }, set: { options.setKeystrokes($0) }))
            if options.showKeystrokes, !Accessibility.trusted {
                Text("Keystrokes need Accessibility access")
            }
            Divider()
            Toggle("Hide Desktop Icons", isOn: $options.hideDesktopIcons)
            Picker("Countdown", selection: $options.countdown) {
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

private struct BarButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(active ? 0.2 : hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: active)
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
