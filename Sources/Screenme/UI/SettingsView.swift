import SwiftUI

/// Settings window. Stub; the full settings replace this.
@MainActor
enum SettingsWindow {
    static func show() {
        WindowPresenter.shared.show("settings", title: "Screenme Settings", size: CGSize(width: 520, height: 400),
                                    style: [.titled, .closable], transparentTitlebar: false) {
            Text("Settings").frame(width: 520, height: 400)
        }
    }
}
