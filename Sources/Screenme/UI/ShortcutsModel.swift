import AppKit
import Combine

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
}

/// The one place the UI reads shortcut state from: Screenme's combos, what macOS and other apps hold,
/// and the status of every action. It updates itself from `.shortcutsChanged`, `HotKeyCenter.conflicts`,
/// apps launching and quitting, and Screenme becoming active (the user may have changed System Settings).
/// When what others hold changes, it re-registers Screenme's shortcuts so freed keys start working.
@MainActor
final class ShortcutsModel: ObservableObject {
    static let shared = ShortcutsModel()

    @Published private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    @Published private(set) var statuses: [ShortcutAction: ShortcutStatus] = [:]
    @Published private(set) var system = SystemShortcuts.State()
    /// True while a takeover or restore is being written.
    @Published private(set) var isWorking = false

    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        system = SystemShortcuts.read()
        reloadCombos()

        let center = NotificationCenter.default
        center.publisher(for: .shortcutsChanged)
            .sink { [weak self] _ in self?.reloadCombos() }
            .store(in: &subscriptions)
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        HotKeyCenter.shared.$conflicts
            .sink { [weak self] conflicts in self?.updateStatuses(conflicts: conflicts) }
            .store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    func combo(for action: ShortcutAction) -> KeyCombo? { combos[action] }
    func status(for action: ShortcutAction) -> ShortcutStatus { statuses[action] ?? .unassigned }

    /// Re-reads what macOS and other apps hold, and re-registers Screenme's shortcuts when that changed.
    func refresh() {
        let now = SystemShortcuts.read()
        guard now != system else { return }
        let freedOrTaken = now.screenshotEntries != system.screenshotEntries || now.rivals != system.rivals
        system = now
        updateStatuses()
        if freedOrTaken { registerHotKeys() }
    }

    // MARK: Actions

    func takeOver() { write(SystemShortcuts.takeOver) }
    func restore() { write(SystemShortcuts.restore) }

    /// Quits a rival app. Its termination notification refreshes the model.
    func quit(_ app: SystemShortcuts.RivalApp) { SystemShortcuts.quit(app) }

    private func write(_ work: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await work()
            isWorking = false
            system = SystemShortcuts.read()
            updateStatuses()
            registerHotKeys()
        }
    }

    // MARK: Updating

    private func reloadCombos() {
        let next = ShortcutStore.allCombos()
        if next != combos { combos = next }
        updateStatuses()
    }

    private func updateStatuses(conflicts: Set<ShortcutAction>? = nil) {
        let conflicts = conflicts ?? HotKeyCenter.shared.conflicts
        var next: [ShortcutAction: ShortcutStatus] = [:]
        for action in ShortcutAction.allCases {
            next[action] = {
                guard let combo = combos[action] else { return .unassigned }
                if let entry = system.macOSShortcut(using: combo) { return .usedByMacOS(entry.name) }
                if conflicts.contains(action) { return .usedByApp(running: system.rivals.map(\.name)) }
                return .ok
            }()
        }
        if next != statuses { statuses = next }
    }

    /// A recorder that is listening has released the shortcuts on purpose; it re-registers when done.
    private func registerHotKeys() {
        if !ShortcutRecorderModel.isAnyRecording { HotKeyCenter.shared.registerAll() }
    }
}
