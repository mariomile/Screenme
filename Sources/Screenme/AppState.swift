import AppKit
import ServiceManagement

/// Preferences and system requirements, observed by onboarding and settings.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard

    @Published var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published var shortcutsRegistered = true
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var onboardingStep: Int {
        didSet { defaults.set(onboardingStep, forKey: "onboardingStep") }
    }
    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: "onboardingDone") }
    }
    @Published var copyAfterCapture: Bool {
        didSet { defaults.set(copyAfterCapture, forKey: "copyAfterCapture") }
    }
    @Published var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: "saveDirectory") }
    }

    /// Set by the app delegate so onboarding can re-register shortcuts.
    var retryShortcuts: () -> Bool = { true }

    private init() {
        onboardingStep = defaults.integer(forKey: "onboardingStep")
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        copyAfterCapture = defaults.object(forKey: "copyAfterCapture") as? Bool ?? true
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        saveDirectory = defaults.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0) } ?? desktop
    }

    var needsSetup: Bool { !onboardingDone || !screenRecordingGranted || !shortcutsRegistered }

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Screen recording

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
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Shortcuts

    /// Apps known to claim ⌘⇧1 or ⌘⇧2 by default.
    var conflictingApps: [NSRunningApplication] {
        let known = ["cc.ffitch.shottr", "com.getcleanshot.app", "com.getcleanshot.app-setapp", "pl.maketheweb.cleanshotx"]
        return NSWorkspace.shared.runningApplications.filter { known.contains($0.bundleIdentifier ?? "") }
    }

    func quitConflictingApps() {
        conflictingApps.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            shortcutsRegistered = retryShortcuts()
        }
    }

    func checkShortcuts() {
        shortcutsRegistered = retryShortcuts()
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

    func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
        }
    }
}
