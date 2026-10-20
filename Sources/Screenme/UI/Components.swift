import ApplicationServices
import AVFoundation
import AppKit
import SwiftUI

// MARK: - Permissions

/// Live status of the permissions Screenme can use. Screen Recording lives in `AppState`.
@MainActor
final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()

    enum Status { case granted, notDetermined, denied }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var camera: Status = .notDetermined
    @Published private(set) var accessibility = false

    private init() { refresh() }

    func refresh() {
        AppState.shared.refresh()
        let mic = Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        let cam = Self.status(AVCaptureDevice.authorizationStatus(for: .video))
        let ax = AXIsProcessTrusted()
        if mic != microphone { microphone = mic }
        if cam != camera { camera = cam }
        if ax != accessibility { accessibility = ax }
    }

    private static func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    // MARK: Requests

    func requestMicrophone() {
        // Asking without a usage description in Info.plist aborts the process, so fall back to System Settings.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              microphone == .notDetermined else { return openSettings(.microphone) }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionsModel.shared.refresh() } }
        }
    }

    func requestCamera() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil,
              camera == .notDetermined else { return openSettings(.camera) }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionsModel.shared.refresh() } }
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case accessibility = "Privacy_Accessibility"
    }

    func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }
}

// MARK: - Shortcut status

/// What is wrong, if anything, with one Screenme shortcut.
enum ShortcutStatus: Equatable {
    case unassigned
    case ok
    case usedByMacOS(String)
    case usedByApp(running: [String])

    var isWarning: Bool {
        switch self {
        case .usedByMacOS, .usedByApp: true
        default: false
        }
    }

    var text: String {
        switch self {
        case .unassigned: "No shortcut"
        case .ok: "Ready"
        case .usedByMacOS(let name): "In use by macOS: \(name)"
        case .usedByApp(let running):
            running.isEmpty ? "In use by another app" : "In use by another app (\(running.joined(separator: ", ")) is running)"
        }
    }

    @MainActor
    static func of(_ action: ShortcutAction, combo: KeyCombo?) -> ShortcutStatus {
        guard let combo else { return .unassigned }
        if let entry = SystemShortcuts.shared.macOSShortcut(using: combo) { return .usedByMacOS(entry.name) }
        if HotKeyCenter.shared.conflicts.contains(action) {
            return .usedByApp(running: SystemShortcuts.shared.rivals.map(\.name))
        }
        return .ok
    }
}

// MARK: - Small views

/// A keyboard shortcut drawn as separate keycaps: "⇧ ⌘ 4".
struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(combo).enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .frame(minWidth: size * 1.7)
                    .padding(.horizontal, part.count > 1 ? 4 : 0)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.display)
    }

    static func parts(_ combo: KeyCombo) -> [String] {
        let display = combo.display
        let modifiers = display.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = String(display.dropFirst(modifiers.count))
        return modifiers.map(String.init) + [key]
    }
}

/// A rounded-square symbol tile, like the icons in System Settings.
struct SymbolTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// "Granted", "Not allowed", etc. as a colored label.
struct StatusLabel: View {
    enum Tone { case good, warning, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var symbol: String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "circle.dashed"
        }
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

/// One permission: icon, what it is for, live status, and the right button.
struct PermissionRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let granted: Bool
    var deniedHint: String = "Not allowed"
    var primaryTitle: String = "Allow"
    let primary: () -> Void
    let openSettings: () -> Void
    var showOpenSettings = true

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                StatusLabel(text: "Allowed", tone: .good)
            } else {
                HStack(spacing: 8) {
                    StatusLabel(text: deniedHint, tone: .neutral)
                    Button(primaryTitle, action: primary)
                    if showOpenSettings {
                        Button("Open Settings", action: openSettings)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Live polling while a view is on screen.
struct PollingModifier: ViewModifier {
    let interval: TimeInterval
    let tick: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: tick)
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in tick() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick() }
    }
}

extension View {
    func polling(every interval: TimeInterval = 1, _ tick: @escaping () -> Void) -> some View {
        modifier(PollingModifier(interval: interval, tick: tick))
    }
}
