import AppKit
import ServiceManagement

/// System requirements and app-wide live state. Preferences live in `Prefs`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var isRecording = false

    var needsSetup: Bool {
        !Prefs[Pref.onboardingDone] || !screenRecordingGranted || !HotKeyCenter.shared.conflicts.isEmpty
    }

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Screen recording permission

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openScreenRecordingSettings()
        }
        refresh()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// macOS applies a new Screen Recording grant only to a fresh process.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Screenme: launch at login change failed: \(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: Save folder

    var saveDirectory: URL { URL(fileURLWithPath: Prefs[Pref.saveDirectory]) }

    func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Prefs[Pref.saveDirectory] = url.path
            objectWillChange.send()
        }
    }
}
