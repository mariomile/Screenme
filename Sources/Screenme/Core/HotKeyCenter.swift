import Carbon.HIToolbox
import Foundation

/// Global shortcuts via Carbon hot keys: no Accessibility permission needed.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// Actions whose shortcut another app (or macOS) already holds.
    @Published private(set) var conflicts: Set<ShortcutAction> = []

    var onTrigger: (ShortcutAction) -> Void = { _ in }

    /// 'SCME', the signature of every Screenme shortcut.
    nonisolated static let signature = OSType(0x5343_4D45)

    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var ids: [UInt32: ShortcutAction] = [:]

    private init() {
        for (index, action) in ShortcutAction.allCases.enumerated() { ids[UInt32(index + 1)] = action }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Other hot keys in the process (the self-timer's Esc) use their own signature and ids.
            guard hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = HotKeyCenter.shared
                    if let action = center.ids[id] { center.onTrigger(action) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.registerAll() }
        }
    }

    /// (Re)registers every action from `ShortcutStore`. Safe to call any time.
    func registerAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        var failed: Set<ShortcutAction> = []
        for (id, action) in ids {
            guard let combo = ShortcutStore.combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref } else { failed.insert(action) }
        }
        conflicts = failed
    }

    /// Temporarily releases all shortcuts, e.g. while a shortcut recorder is listening.
    func suspend() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}
