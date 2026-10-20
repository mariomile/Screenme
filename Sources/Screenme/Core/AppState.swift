import AppKit
import ServiceManagement

/// App-wide live state: recording, launch at login, the save folder. Preferences live in `Prefs`,
/// permissions in `Permissions`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var isRecording = false

    var needsSetup: Bool {
        // Shortcut conflicts are shown in Settings; they don't reopen setup on every launch.
        !Prefs[Pref.onboardingDone] || !Permission.screenRecording.isGranted
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        FocusKeeper.activateSelf()
        if panel.runModal() == .OK, let url = panel.url {
            Prefs[Pref.saveDirectory] = url.path
            objectWillChange.send()
        }
    }
}
