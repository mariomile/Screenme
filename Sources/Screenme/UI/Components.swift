import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Small views

/// A keyboard shortcut drawn as separate keycaps: "⇧ ⌘ 4".
struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(combo).enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .frame(minWidth: size * 1.7)
                    .padding(.horizontal, part.count > 1 ? 4 : 0)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.display)
    }

    static func parts(_ combo: KeyCombo) -> [String] {
        let display = combo.display
        let modifiers = display.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = String(display.dropFirst(modifiers.count))
        return modifiers.map(String.init) + [key]
    }
}

/// A rounded-square symbol tile, like the icons in System Settings.
struct SymbolTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// "Allowed", "macOS uses it", "Ready" and the like, as a colored label with the tone's symbol.
struct StatusLabel: View {
    enum Tone {
        case good, warning, neutral

        var symbol: String {
            switch self {
            case .good: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .neutral: "circle.dashed"
            }
        }

        var color: Color {
            switch self {
            case .good: .green
            case .warning: .orange
            case .neutral: .secondary
            }
        }
    }

    let text: String
    let tone: Tone
    var font: Font = .callout

    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(font)
            .foregroundStyle(tone.color)
            .labelStyle(.titleAndIcon)
    }
}

extension ShortcutStatus {
    var tone: StatusLabel.Tone {
        switch self {
        case .ok: .good
        case .unassigned: .neutral
        case .usedByMacOS, .usedByApp: .warning
        }
    }

    var symbol: String { tone.symbol }

    /// For tight rows: "Ready", "No shortcut", "macOS uses it", "Another app uses it".
    var shortText: String {
        switch self {
        case .usedByMacOS: "macOS uses it"
        case .usedByApp: "Another app uses it"
        default: text
        }
    }
}

/// One permission: icon, what it is for, live status, and one button titled from the status.
struct PermissionRow: View {
    let permission: Permission
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: permission.symbol, color: permission.color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.body.weight(.medium))
                Text(permission.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if permissions.isGranted(permission) {
                StatusLabel(text: permission.statusText, tone: .good)
            } else {
                HStack(spacing: 8) {
                    StatusLabel(text: permission.statusText, tone: .neutral)
                    Button(permission.requestTitle) { permission.request() }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bound controls

/// A switch bound to a Bool preference.
struct PrefToggle: View {
    let title: String
    var detail: String?
    @AppStorage private var value: Bool

    init(_ title: String, _ key: PrefKey<Bool>, detail: String? = nil) {
        self.title = title
        self.detail = detail
        _value = AppStorage(wrappedValue: key.defaultValue, key.name)
    }

    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A pop-up bound to an Int preference.
struct PrefIntPicker: View {
    let title: String
    let options: [(label: String, value: Int)]
    @AppStorage private var value: Int

    init(_ title: String, _ key: PrefKey<Int>, options: [(label: String, value: Int)]) {
        self.title = title
        self.options = options
        _value = AppStorage(wrappedValue: key.defaultValue, key.name)
    }

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }
}

// MARK: - Rows shared by Settings and onboarding

/// What happens after a screenshot, for a grouped form.
struct AfterCaptureSection: View {
    var title = "After capture"
    /// Onboarding has no room for the explanation.
    var showsFooter = true

    var body: some View {
        Section {
            PrefToggle("Show Quick Access", Pref.afterShotQuickAccess)
            PrefToggle("Copy to clipboard", Pref.afterShotCopy)
            PrefToggle("Save to folder", Pref.afterShotSave)
            PrefToggle("Open in editor", Pref.afterShotOpenEditor)
            PrefToggle("Pin to screen", Pref.afterShotPin)
        } header: {
            Text(title)
        } footer: {
            if showsFooter {
                Text("Pick any combination. Copy puts the image on the clipboard, Save puts a file in your save folder (Settings > General). With Open in editor on, the editor opens instead of Quick Access.")
            }
        }
    }
}

/// The folder Save copies captures to, with a button to choose another.
struct SaveFolderRow: View {
    @AppStorage(Pref.saveDirectory.name) private var saveDirectory = Pref.saveDirectory.defaultValue

    var body: some View {
        LabeledContent("Save folder") {
            HStack {
                Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { AppState.shared.chooseSaveDirectory() }
            }
        }
    }
}

/// The login item switch, plus the hint macOS needs when the login item waits for approval.
struct LaunchAtLoginToggle: View {
    @ObservedObject private var state = AppState.shared
    @State private var status = SMAppService.mainApp.status

    /// Two rows in a form: the switch, and the approval hint when needed.
    var body: some View {
        Toggle("Launch Screenme at login", isOn: Binding(
            get: { state.launchAtLogin },
            set: {
                state.setLaunchAtLogin($0)
                status = SMAppService.mainApp.status
            }
        ))
        .polling(every: 2) {
            state.refresh()
            status = SMAppService.mainApp.status
        }
        if status == .requiresApproval {
            HStack {
                Label("Approve Screenme in Login Items to finish.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }
}

// MARK: - Polling

/// Live polling while a view is on screen.
struct PollingModifier: ViewModifier {
    let interval: TimeInterval
    let tick: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: tick)
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in tick() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick() }
    }
}

extension View {
    func polling(every interval: TimeInterval = 1, _ tick: @escaping () -> Void) -> some View {
        modifier(PollingModifier(interval: interval, tick: tick))
    }
}
