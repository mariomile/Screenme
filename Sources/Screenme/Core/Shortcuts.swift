import AppKit
import Carbon.HIToolbox

/// Everything a global shortcut can trigger.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case allInOne
    case captureArea
    case captureFullscreen
    case captureWindow
    case capturePreviousArea
    case captureText
    case translateText
    case pickColor
    case measure
    case scrollingCapture
    case selfTimer
    case recordScreen
    case pinLastCapture
    case openHistory
    case toggleDesktopIcons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: "All-in-One"
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureText: "Capture Text (OCR)"
        case .translateText: "Capture & Translate Text"
        case .pickColor: "Pick Color"
        case .measure: "Measure"
        case .scrollingCapture: "Scrolling Capture"
        case .selfTimer: "Self-Timer"
        case .recordScreen: "Record Screen"
        case .pinLastCapture: "Pin Last Capture"
        case .openHistory: "Capture History"
        case .toggleDesktopIcons: "Hide/Show Desktop Icons"
        }
    }

    /// What it is for, shown when the pointer rests on it. One line: what it does, then why you would.
    var help: String {
        switch self {
        case .allInOne: "Opens a bar with every capture mode, so you can pick one without remembering its shortcut."
        case .captureArea: "Drag to capture part of the screen. Press Space to switch to window capture. While you hold the button, the arrow keys move the selection by 1 pt (Shift: 10 pt), Option with an arrow resizes it from the bottom and right edges, and Return captures it. To take several shots of the same or an adjusted area, turn on Repeat in the All-in-One bar first: the picker stays open until Esc."
        case .captureWindow: "Click a window to capture just that window, with its shadow if turned on."
        case .captureFullscreen: "Captures the whole screen the pointer is on, right away."
        case .capturePreviousArea: "Captures the same area as your last area capture, without selecting again."
        case .captureText: "Select an area and its text is copied to the clipboard. Reads QR codes too."
        case .translateText: "Select an area: its text is recognized, translated on this Mac and copied."
        case .pickColor: "Click any pixel on screen to copy its color, as HEX or the format chosen in Settings."
        case .measure: "Shows the distance between edges under the pointer; drag to measure a box. Click or ⌘C copies it."
        case .scrollingCapture: "Select an area, then scroll: the pages are stitched into one tall image."
        case .selfTimer: "Select an area; the capture happens after a countdown, so you can open a menu or hover something first."
        case .recordScreen: "Record an area, a window or the screen as a video or a GIF. Press again to stop."
        case .pinLastCapture: "Keeps your last screenshot floating above all windows, as a reference while you work."
        case .openHistory: "Browse, reopen, share or combine everything you captured recently."
        case .toggleDesktopIcons: "Hides the icons on your desktop for clean screenshots. Run it again to show them."
        }
    }

    /// Title, shortcut and what it does, for a tooltip.
    @MainActor var tooltip: String {
        let shortcut = ShortcutsModel.shared.combo(for: self).map { "  \($0.display)" } ?? ""
        return Tooltip.text(title + shortcut, help)
    }

    var symbol: String {
        switch self {
        case .allInOne: "square.grid.2x2"
        case .captureArea: "rectangle.dashed"
        case .captureFullscreen: "macwindow.on.rectangle"
        case .captureWindow: "macwindow"
        case .capturePreviousArea: "arrow.counterclockwise.rectangle"
        case .captureText: "text.viewfinder"
        case .translateText: "translate"
        case .pickColor: "eyedropper"
        case .measure: "ruler"
        case .scrollingCapture: "arrow.up.and.down.text.horizontal"
        case .selfTimer: "timer"
        case .recordScreen: "record.circle"
        case .pinLastCapture: "pin"
        case .openHistory: "clock.arrow.circlepath"
        case .toggleDesktopIcons: "eye.slash"
        }
    }

    /// False for actions that only show what Screenme already has, and for Pick Color, whose system loupe needs no permission.
    var requiresScreenRecording: Bool {
        switch self {
        case .pinLastCapture, .openHistory, .toggleDesktopIcons, .pickColor: false
        default: true
        }
    }

    /// True for actions that save a screenshot, which hide the desktop icons when Settings ask for it.
    /// Recordings have their own setting, text recognition keeps no picture, and Pick Color and Measure
    /// read the screen as the user sees it.
    var writesScreenshot: Bool {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea, .selfTimer, .scrollingCapture: true
        case .allInOne, .captureText, .translateText, .pickColor, .measure, .recordScreen,
             .pinLastCapture, .openHistory, .toggleDesktopIcons: false
        }
    }

    /// CleanShot-style defaults: Screenme takes over the macOS screenshot shortcuts.
    var defaultCombo: KeyCombo? {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift)
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift)
        case .recordScreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdShift)
        case .captureText: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift)
        case .allInOne: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift)
        default: return nil
        }
    }
}

/// A key plus Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From an AppKit key event, e.g. in a shortcut recorder.
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        modifiers = carbon
    }

    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// "⌃⌥⇧⌘4", in macOS modifier order, using the current keyboard layout for the key.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The character for `keyCode` (menus need it as a key equivalent).
    var keyEquivalent: String { Self.keyName(keyCode).lowercased() }

    static func keyName(_ keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// User-chosen shortcuts, persisted. A missing entry means "use the default";
/// an explicit `nil` (stored as empty) means "no shortcut".
enum ShortcutStore {
    static func combo(for action: ShortcutAction) -> KeyCombo? {
        allCombos()[action]
    }

    /// The combo of every action that has one; an action without a shortcut is absent. The one source for the
    /// global hot keys, the menu's key equivalents and the UI.
    static func allCombos() -> [ShortcutAction: KeyCombo] {
        var combos: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases { combos[action] = action.defaultCombo }
        // A saved entry replaces the default; a saved "no shortcut" removes it.
        for (name, combo) in load() {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            combos[action] = combo
        }
        return combos
    }

    static func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        var saved = load()
        saved[action.rawValue] = .some(combo)
        if let data = try? JSONEncoder().encode(saved) { Prefs[Pref.shortcuts] = data }
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    static func resetAll() {
        Prefs.remove(Pref.shortcuts)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    /// The action already using `combo`, if any.
    static func action(using combo: KeyCombo) -> ShortcutAction? {
        let all = allCombos()
        return ShortcutAction.allCases.first { all[$0] == combo }
    }

    private static func load() -> [String: KeyCombo?] {
        (try? JSONDecoder().decode([String: KeyCombo?].self, from: Prefs[Pref.shortcuts])) ?? [:]
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("ScreenmeShortcutsChanged")
}
