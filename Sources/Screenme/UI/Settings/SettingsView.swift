import AppKit
import SwiftUI

// MARK: - Window

@MainActor
enum SettingsWindow {
    static func show() {
        let window = WindowPresenter.shared.show("settings", title: "Screenme Settings", size: CGSize(width: 800, height: 580),
                                                 style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) {
            SettingsView()
        }
        window.contentMinSize = CGSize(width: 720, height: 480)
    }

    static func show(tab: SettingsTab) {
        Prefs[Pref.settingsTab] = tab
        show()
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, screenshots, quickAccess, recording, text, shortcuts, permissions, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .quickAccess: "Quick Access"
        case .recording: "Recording"
        case .text: "Text Recognition"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .screenshots: "camera.viewfinder"
        case .quickAccess: "rectangle.on.rectangle"
        case .recording: "record.circle.fill"
        case .text: "text.viewfinder"
        case .shortcuts: "command"
        case .permissions: "lock.shield.fill"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .screenshots: .blue
        case .quickAccess: .indigo
        case .recording: .red
        case .text: .teal
        case .shortcuts: .orange
        case .permissions: .green
        case .history: .purple
        case .about: .gray
        }
    }
}

/// The Settings shell: a sidebar of tabs and the selected pane. Each pane lives in its own file.
struct SettingsView: View {
    @AppStorage(Pref.settingsTab.name) private var tab = Pref.settingsTab.defaultValue

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
                .background(VisualEffectBackground(material: .sidebar, state: .followsWindowActiveState).ignoresSafeArea())
            Divider().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                pane
                    .id(tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .animation(.easeOut(duration: 0.15), value: tab)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 9) {
                        SymbolTile(symbol: item.symbol, color: item.color, size: 22)
                        Text(item.title).font(.system(size: 13.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .foregroundStyle(item == tab ? Color.white : Color.primary)
                    .background(item == tab ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = SettingsTab.allCases
            guard let index = all.firstIndex(of: tab) else { return }
            switch direction {
            case .up: tab = all[max(index - 1, 0)]
            case .down: tab = all[min(index + 1, all.count - 1)]
            default: break
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane()
        case .screenshots: ScreenshotsPane()
        case .quickAccess: QuickAccessPane()
        case .recording: RecordingPane()
        case .text: TextRecognitionPane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .history: HistoryPane()
        case .about: AboutPane()
        }
    }
}
