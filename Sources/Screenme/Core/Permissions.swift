import ApplicationServices
import AVFoundation
import AppKit
import SwiftUI

/// Everything macOS asks the user to allow. `status` is read live; views observe `Permissions.shared`.
enum Permission: CaseIterable, Identifiable {
    case screenRecording, microphone, camera, accessibility

    enum Status { case granted, notDetermined, denied }

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: "Required to take screenshots and record the screen."
        case .microphone: "Records your voice in screen recordings."
        case .camera: "Shows your webcam in screen recordings."
        case .accessibility: "Shows keystrokes in recordings and drives scrolling capture."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        case .accessibility: "accessibility"
        }
    }

    var color: Color {
        switch self {
        case .screenRecording: .blue
        case .microphone: .red
        case .camera: .gray
        case .accessibility: .indigo
        }
    }

    /// macOS only reports a refusal for the microphone and camera. Screen Recording and Accessibility
    /// read as not determined until they are granted, so asking again stays possible.
    var status: Status {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility: AXIsProcessTrusted() ? .granted : .notDetermined
        case .microphone, .camera:
            switch AVCaptureDevice.authorizationStatus(for: mediaType) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        }
    }

    var isGranted: Bool { status == .granted }

    /// "Allowed", "Not asked yet", "Not allowed".
    var statusText: String {
        switch status {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: self == .microphone || self == .camera ? "Not asked yet" : "Not allowed"
        }
    }

    /// The label of the button that runs `request()`.
    var requestTitle: String { status == .denied ? "Open Settings" : "Allow" }

    /// Shows the system prompt, or opens System Settings when macOS will not ask again.
    @MainActor
    func request() {
        switch self {
        case .screenRecording:
            // Only the first request shows a prompt; after that macOS just returns false.
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .accessibility:
            // The prompt also adds Screenme to the list in System Settings and offers to open it.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .microphone, .camera:
            guard status == .notDetermined else { return openSettings() }
            AVCaptureDevice.requestAccess(for: mediaType) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Permissions.shared.refresh() } }
            }
        }
        Permissions.shared.refresh()
    }

    /// For the microphone and camera before using them: true when allowed, asking the first time.
    /// When refused, says so and opens System Settings.
    @MainActor
    func ensure() async -> Bool {
        if status == .notDetermined, self == .microphone || self == .camera {
            _ = await AVCaptureDevice.requestAccess(for: mediaType)
            Permissions.shared.refresh()
        }
        guard !isGranted else { return true }
        Toast.show("\(title) access is off. Allow Screenme in Privacy settings.",
                   symbol: self == .microphone ? "mic.slash.fill" : "video.slash.fill", duration: 3)
        openSettings()
        return false
    }

    @MainActor
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)")!)
    }

    private var settingsPane: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    private var mediaType: AVMediaType { self == .microphone ? .audio : .video }
}

/// Live permission statuses for SwiftUI. Views poll `refresh()` while they are on screen.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var statuses: [Permission: Permission.Status] = [:]

    private init() { refresh() }

    func status(_ permission: Permission) -> Permission.Status { statuses[permission] ?? permission.status }
    func isGranted(_ permission: Permission) -> Bool { status(permission) == .granted }

    func refresh() {
        let current = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.status) })
        if current != statuses { statuses = current }
    }
}
