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

    /// A native sidebar list: clicking a row or using the arrow keys selects it.
    private var sidebar: some View {
        List(SettingsTab.allCases, selection: Binding<SettingsTab?>(get: { tab }, set: { if let new = $0 { tab = new } })) { item in
            Label {
                Text(item.title).font(.system(size: 13.5))
            } icon: {
                SymbolTile(symbol: item.symbol, color: item.color, size: 22)
            }
            .padding(.vertical, 3)
            .tag(item)
        }
        .listStyle(.sidebar)
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
