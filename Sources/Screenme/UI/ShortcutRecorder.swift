import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Recorder model

/// Records one shortcut for one action. While listening, every global shortcut is released so the keys reach us.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    private static weak var active: ShortcutRecorderModel?
    static var isAnyRecording: Bool { active?.isRecording ?? false }

    let action: ShortcutAction
    @Published private(set) var isRecording = false
    @Published private(set) var preview = ""
    @Published private(set) var error: String?
    @Published private(set) var shakes = 0

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var lastClickCancel: CFTimeInterval = 0
    private var errorTask: Task<Void, Never>?

    init(action: ShortcutAction) { self.action = action }

    func toggle() {
        if isRecording {
            finish()
        } else if CACurrentMediaTime() - lastClickCancel > 0.25 {
            start()
        }
    }

    func cancel() {
        if isRecording { finish() }
    }

    private func start() {
        Self.active?.cancel()
        Self.active = self
        error = nil
        preview = ""
        isRecording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated { self.handle(event) }
            return swallow ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        isRecording = false
        preview = ""
        if Self.active === self { Self.active = nil }
        HotKeyCenter.shared.registerAll()
    }

    /// True when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // A click anywhere stops listening. The recorder's own button then ignores the click it just got.
            lastClickCancel = CACurrentMediaTime()
            finish()
            return false
        case .flagsChanged:
            preview = Self.glyphs(event.modifierFlags)
            return true
        case .keyDown:
            handleKey(event)
            return true
        default:
            return false
        }
    }

    private func handleKey(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.isARepeat { return }

        if code == kVK_Escape && modifiers.isEmpty { return finish() }
        if (code == kVK_Delete || code == kVK_ForwardDelete) && modifiers.isEmpty {
            ShortcutStore.set(nil, for: action)
            return finish()
        }
        if !Self.functionKeys.contains(code) && modifiers.isDisjoint(with: [.command, .option, .control]) {
            return reject("Add ⌘, ⌥ or ⌃ to the shortcut")
        }
        let combo = KeyCombo(event: event)
        if let other = ShortcutStore.action(using: combo), other != action {
            return reject("\(combo.display) is already used by \(other.title)")
        }
        ShortcutStore.set(combo, for: action)
        finish()
    }

    private func reject(_ message: String) {
        error = message
        shakes += 1
        NSSound.beep()
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.error = nil
        }
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
}

// MARK: - Recorder field

private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 3), y: 0))
    }
}

/// Click to record. Shows the current shortcut as keycaps.
struct ShortcutRecorderField: View {
    @ObservedObject var model: ShortcutRecorderModel
    let combo: KeyCombo?

    var body: some View {
        Button { model.toggle() } label: {
            ZStack {
                if model.isRecording {
                    Text(model.preview.isEmpty ? "Type shortcut…" : model.preview)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.preview.isEmpty ? Color.secondary : Color.primary)
                } else if let combo {
                    KeyCaps(combo: combo, size: 11)
                } else {
                    Text("Record shortcut")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(model.isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(model.isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: model.isRecording ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ShakeEffect(shakes: CGFloat(model.shakes)))
        .animation(.easeInOut(duration: 0.4), value: model.shakes)
        .animation(.easeOut(duration: 0.12), value: model.isRecording)
        .help(model.isRecording ? "Press the new shortcut. Esc cancels, Delete clears." : "Click, then press the new shortcut")
        .accessibilityLabel("Shortcut for \(model.action.title)")
        .accessibilityValue(combo?.display ?? "None")
    }
}

// MARK: - One row per action

struct ShortcutRow: View {
    let action: ShortcutAction
    @StateObject private var recorder: ShortcutRecorderModel
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    init(action: ShortcutAction) {
        self.action = action
        _recorder = StateObject(wrappedValue: ShortcutRecorderModel(action: action))
    }

    var body: some View {
        let combo = shortcuts.combo(for: action)
        let status = shortcuts.status(for: action)
        HStack(spacing: 12) {
            SymbolTile(symbol: action.symbol, color: .accentColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.body)
                if let error = recorder.error {
                    Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                } else {
                    StatusLabel(text: status.text, tone: status.tone, font: .caption)
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorderField(model: recorder, combo: combo)
            Button {
                ShortcutStore.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(combo == nil || recorder.isRecording ? 0 : 1)
            .help("Remove shortcut")
            .accessibilityLabel("Remove shortcut for \(action.title)")
        }
        .padding(.vertical, 2)
        .onDisappear { recorder.cancel() }
    }
}

// MARK: - macOS takeover

/// The state of the macOS screenshot shortcuts and the buttons to take them over or give them back.
/// Settings lists each shortcut; onboarding, short on room, shows one summary line instead.
struct MacOSShortcutsBlock: View {
    var listsEach = true
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if listsEach {
                ForEach(shortcuts.system.screenshotEntries) { entry in
                    HStack(spacing: 10) {
                        if let combo = entry.combo { KeyCaps(combo: combo, size: 11) }
                        Text(entry.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        if entry.enabled {
                            StatusLabel(text: "macOS uses it", tone: .warning)
                        } else {
                            StatusLabel(text: "Free for Screenme", tone: .good)
                        }
                    }
                }
            } else if shortcuts.system.macOSOwnsScreenshotShortcuts {
                StatusLabel(text: "macOS still uses ⇧⌘3, ⇧⌘4 and ⇧⌘5", tone: .warning)
            } else {
                StatusLabel(text: "The macOS screenshot shortcuts are off", tone: .good)
            }
            HStack(spacing: 10) {
                if shortcuts.system.macOSOwnsScreenshotShortcuts {
                    Button("Use Screenme for ⇧⌘3, ⇧⌘4, ⇧⌘5") { shortcuts.takeOver() }
                        .buttonStyle(.borderedProminent)
                }
                if shortcuts.system.screenshotEntries.contains(where: { !$0.enabled }) {
                    Button("Restore macOS shortcuts") { shortcuts.restore() }
                }
                if shortcuts.isWorking { ProgressView().controlSize(.small) }
            }
        }
    }
}

/// Known screenshot apps that are running, each with a Quit button.
struct RivalAppsBlock: View {
    @ObservedObject private var shortcuts = ShortcutsModel.shared

    var body: some View {
        ForEach(shortcuts.system.rivals) { app in
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(app.name) is running")
                    Text("It may claim the same screenshot shortcuts.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit \(app.name)") { shortcuts.quit(app) }
            }
        }
    }
}
