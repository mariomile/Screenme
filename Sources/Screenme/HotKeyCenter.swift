import Carbon.HIToolbox

/// Global shortcuts via Carbon hot keys: no Accessibility permission needed.
final class HotKeyCenter {
    private struct Shortcut {
        let keyCode: Int
        let modifiers: Int
        var ref: EventHotKeyRef?
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// True when every shortcut is registered; false when another app holds one of them.
    var allRegistered: Bool { shortcuts.values.allSatisfy { $0.ref != nil } }

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        shortcuts[id] = Shortcut(keyCode: keyCode, modifiers: modifiers)
        attempt(id)
    }

    /// Tries again the shortcuts that were taken, e.g. after the user quits a conflicting app.
    @discardableResult
    func retry() -> Bool {
        for id in shortcuts.keys where shortcuts[id]?.ref == nil { attempt(id) }
        return allRegistered
    }

    private func attempt(_ id: UInt32) {
        guard let shortcut = shortcuts[id] else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5343_4D45), id: id) // "SCME"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        shortcuts[id]?.ref = status == noErr ? ref : nil
    }
}
