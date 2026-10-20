import AppKit
import Carbon.HIToolbox

extension Pref {
    /// JSON, owned by `SystemShortcuts`: the macOS screenshot shortcuts as they were before Screenme took them over.
    /// Empty when there was no takeover, or after a restore.
    static let macOSScreenshotShortcutsBackup = PrefKey(name: "macOSScreenshotShortcutsBackup", defaultValue: Data())
}

/// What macOS and other apps already claim: the symbolic hotkeys behind System Settings > Keyboard > Shortcuts,
/// and running apps known to grab the screenshot shortcuts. Also the explicit "take over" and "restore" writes.
/// Holds no state: `ShortcutsModel` reads it and publishes the result.
@MainActor
enum SystemShortcuts {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let combo: KeyCombo?
        let enabled: Bool
    }

    struct RivalApp: Identifiable, Equatable {
        let id: String // bundle identifier
        let name: String
    }

    /// One reading of what macOS and other apps hold.
    struct State: Equatable {
        /// The macOS screenshot shortcuts (28, 29, 30, 31, 184), enabled or not.
        var screenshotEntries: [Entry] = []
        /// Every enabled symbolic hotkey with a key combo, for collision checks against Screenme's own shortcuts.
        var enabledEntries: [Entry] = []
        var rivals: [RivalApp] = []

        /// True while macOS still owns any of ⇧⌘3, ⇧⌘4, ⇧⌘5 (or the clipboard variants).
        var macOSOwnsScreenshotShortcuts: Bool { screenshotEntries.contains { $0.enabled } }

        /// The enabled macOS shortcut that collides with `combo`, if any.
        func macOSShortcut(using combo: KeyCombo) -> Entry? {
            enabledEntries.first { $0.combo == combo }
        }
    }

    /// One macOS screenshot shortcut as it was before the takeover.
    struct SavedShortcut: Codable, Equatable {
        let id: Int
        /// False when the entry was missing from the plist (macOS then uses its default).
        let existed: Bool
        let enabled: Bool
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let hotKeysKey = "AppleSymbolicHotKeys" as CFString
    private static let activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    /// id, label, default (ascii, keyCode, Cocoa modifier mask) for the five screenshot shortcuts.
    private static let screenshotDefaults: [(id: Int, name: String, parameters: [Int])] = [
        (28, "Save picture of screen as a file", [51, 20, 1_179_648]),
        (29, "Copy picture of screen to the clipboard", [51, 20, 1_441_792]),
        (30, "Save picture of selected area as a file", [52, 21, 1_179_648]),
        (31, "Copy picture of selected area to the clipboard", [52, 21, 1_441_792]),
        (184, "Screenshot and recording options", [53, 23, 1_179_648]),
    ]

    private static let names: [Int: String] = [
        27: "Move focus to next window in app", 32: "Mission Control", 33: "Application windows",
        36: "Show Desktop", 52: "Turn Dock hiding on or off", 60: "Select previous input source",
        61: "Select next input source", 64: "Show Spotlight search", 65: "Show Finder search window",
        79: "Move left a space", 81: "Move right a space", 98: "Show Help menu",
        163: "Show Notification Center", 175: "Turn Do Not Disturb on or off",
    ]

    /// Apps that claim screenshot shortcuts, matched by bundle id prefix or name.
    private static let rivalMatchers: [(prefix: String, name: String)] = [
        ("cc.ffitch.shottr", "Shottr"),
        ("pl.maketheweb.cleanshotx", "CleanShot X"),
        ("com.xnapper", "Xnapper"),
        ("com.techsmith.snagit", "Snagit"),
    ]

    // MARK: Reading

    static func read() -> State {
        let hotKeys = readStored() ?? [:]
        var state = State()
        for item in screenshotDefaults {
            let entry = hotKeys[String(item.id)] as? [String: Any]
            let combo = combo(from: entry) ?? combo(parameters: item.parameters)
            state.screenshotEntries.append(Entry(id: item.id, name: item.name, combo: combo, enabled: isEnabled(entry, default: true)))
        }
        for (key, value) in hotKeys {
            guard let id = Int(key), let entry = value as? [String: Any], isEnabled(entry, default: false),
                  let combo = combo(from: entry) else { continue }
            let name = names[id] ?? screenshotDefaults.first { $0.id == id }?.name ?? desktopName(id) ?? "A macOS shortcut"
            state.enabledEntries.append(Entry(id: id, name: name, combo: combo, enabled: true))
        }
        state.enabledEntries.sort { $0.id < $1.id }
        // Screenshot shortcuts missing from the plist are enabled by default.
        for entry in state.screenshotEntries where entry.enabled && !state.enabledEntries.contains(where: { $0.id == entry.id }) {
            state.enabledEntries.append(entry)
        }
        state.rivals = runningRivals()
        return state
    }

    // MARK: Take over and restore

    /// Turns off the macOS screenshot shortcuts so Screenme can register them. Only call on an explicit click.
    /// The first takeover remembers how each shortcut was set, so `restore()` can put it back exactly.
    static func takeOver() async {
        await write { hotKeys in
            let result = takingOver(hotKeys, backup: loadBackup())
            saveBackup(result.backup)
            return result.hotKeys
        }
    }

    /// Puts the macOS screenshot shortcuts back as they were before the takeover.
    static func restore() async {
        let backup = loadBackup()
        if await write({ restoring($0, backup: backup) }) { Prefs.remove(Pref.macOSScreenshotShortcutsBackup) }
    }

    /// The symbolic hotkeys with the five screenshot shortcuts off, and the state to restore later.
    /// An existing backup is kept: shortcuts that are off now may be off because Screenme turned them off.
    static func takingOver(_ hotKeys: [String: Any], backup: [SavedShortcut]?) -> (hotKeys: [String: Any], backup: [SavedShortcut]) {
        var hotKeys = hotKeys
        let saved = backup ?? screenshotDefaults.map { item in
            let entry = hotKeys[String(item.id)] as? [String: Any]
            return SavedShortcut(id: item.id, existed: entry != nil, enabled: isEnabled(entry, default: true))
        }
        for item in screenshotDefaults {
            var entry = hotKeys[String(item.id)] as? [String: Any] ?? defaultEntry(item.parameters)
            entry["enabled"] = false
            hotKeys[String(item.id)] = entry
        }
        return (hotKeys, saved)
    }

    /// The symbolic hotkeys with the screenshot shortcuts as `backup` recorded them: entries that did not exist are
    /// removed again, the others get their old on or off. With nothing saved, all on (the macOS default).
    static func restoring(_ hotKeys: [String: Any], backup: [SavedShortcut]?) -> [String: Any] {
        var hotKeys = hotKeys
        for item in screenshotDefaults {
            let key = String(item.id)
            let saved = backup?.first { $0.id == item.id }
            if let saved, !saved.existed {
                hotKeys.removeValue(forKey: key)
                continue
            }
            var entry = hotKeys[key] as? [String: Any] ?? defaultEntry(item.parameters)
            entry["enabled"] = saved?.enabled ?? true
            hotKeys[key] = entry
        }
        return hotKeys
    }

    /// Reads, changes and writes back the symbolic hotkeys, then has macOS pick them up.
    /// Writes only when the stored value was read whole, or is truly absent. Returns whether it wrote.
    @discardableResult
    private static func write(_ change: ([String: Any]) -> [String: Any]) async -> Bool {
        // The whole dictionary is written back. If it exists but cannot be read as one, writing would
        // replace every other macOS shortcut with just these five: do nothing instead.
        guard let hotKeys = readStored(),
              screenshotDefaults.allSatisfy({ hotKeys[String($0.id)] == nil || hotKeys[String($0.id)] is [String: Any] }) else {
            NSLog("Screenme: AppleSymbolicHotKeys has an unexpected format; leaving it untouched")
            return false
        }
        CFPreferencesSetAppValue(hotKeysKey, change(hotKeys) as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        if await runActivateSettings() != 0 {
            Toast.show("Shortcuts changed. Log out to apply.", symbol: "arrow.right.square", duration: 3)
        }
        return true
    }

    /// Makes the system pick up the change without a logout. Returns the exit status, -1 when it could not run.
    private static func runActivateSettings() async -> Int32 {
        let path = activateSettings
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-u"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                NSLog("Screenme: activateSettings failed: \(error.localizedDescription)")
                return -1
            }
        }.value
    }

    private static func loadBackup() -> [SavedShortcut]? {
        try? JSONDecoder().decode([SavedShortcut].self, from: Prefs[Pref.macOSScreenshotShortcutsBackup])
    }

    private static func saveBackup(_ saved: [SavedShortcut]) {
        if let data = try? JSONEncoder().encode(saved) { Prefs[Pref.macOSScreenshotShortcutsBackup] = data }
    }

    private static func defaultEntry(_ parameters: [Int]) -> [String: Any] {
        ["value": ["type": "standard", "parameters": parameters] as [String: Any]]
    }

    // MARK: Rival apps

    /// Asks the app to quit. `ShortcutsModel` sees it go through the workspace notifications.
    static func quit(_ app: RivalApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.id).forEach { $0.terminate() }
    }

    private static func runningRivals() -> [RivalApp] {
        var found: [RivalApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? ""
            for matcher in rivalMatchers {
                let byID = id.lowercased().hasPrefix(matcher.prefix)
                let byName = name.range(of: matcher.name, options: .caseInsensitive) != nil
                if (byID || byName), !found.contains(where: { $0.id == id }) {
                    found.append(RivalApp(id: id, name: matcher.name))
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    // MARK: Parsing

    /// The stored symbolic hotkeys: empty when the key is absent, nil when it exists but is not a dictionary.
    private static func readStored() -> [String: Any]? {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue(hotKeysKey, domain) else { return [:] }
        return value as? [String: Any]
    }

    /// An entry's `enabled` flag, which macOS stores as a boolean or a number; `fallback` when it is missing.
    static func isEnabled(_ entry: [String: Any]?, default fallback: Bool) -> Bool {
        if let flag = entry?["enabled"] as? Bool { return flag }
        if let number = entry?["enabled"] as? Int { return number != 0 }
        return fallback
    }

    private static func desktopName(_ id: Int) -> String? {
        (118...126).contains(id) ? "Switch to Desktop \(id - 117)" : nil
    }

    private static func combo(from entry: [String: Any]?) -> KeyCombo? {
        guard let value = entry?["value"] as? [String: Any], let parameters = value["parameters"] as? [Int] else { return nil }
        return combo(parameters: parameters)
    }

    /// parameters = [ascii, keyCode, Cocoa modifier mask]. 65535 / 0 as key code means "no key".
    private static func combo(parameters: [Int]) -> KeyCombo? {
        guard parameters.count >= 3, parameters[1] >= 0, parameters[1] < 0xFFFF else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(parameters[2]))
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return KeyCombo(keyCode: UInt32(parameters[1]), modifiers: carbon)
    }
}
