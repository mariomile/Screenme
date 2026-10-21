import AppKit
import ScreenCaptureKit

/// A `screenme://` link, for Shortcuts, Raycast, scripts and the end-to-end tests:
///
/// - `screenme://capture-fullscreen`, `screenme://open-history`: any action, by its `urlName`.
/// - `screenme://capture-area?x=100&y=80&width=640&height=400`: actions that select something capture that rectangle
///   instead of asking. Global screen points, top-left origin. Recordings then start at once with the saved settings.
/// - `screenme://capture-window?app=com.apple.TextEdit`: the frontmost window of that app (bundle ID or name).
/// - `screenme://settings?tab=recording`: opens Settings, on a tab when one is named (`AppDelegate` handles it).
struct ActionLink {
    enum Target {
        case area(CGRect)
        case window(app: String)
    }

    let action: ShortcutAction
    let target: Target?

    init?(url: URL) {
        guard url.scheme == "screenme", let host = url.host(),
              let action = ShortcutAction.allCases.first(where: { $0.urlName == host }) else { return nil }
        self.action = action
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { _, last in last })
        if let app = query["app"], !app.isEmpty {
            target = .window(app: app)
        } else if let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init),
                  let width = query["width"].flatMap(Double.init), let height = query["height"].flatMap(Double.init),
                  width > 0, height > 0 {
            target = .area(CGRect(x: x, y: y, width: width, height: height))
        } else {
            target = nil
        }
    }
}

extension ShortcutAction {
    /// The action's name in `screenme://` links: `captureArea` is `capture-area`.
    var urlName: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "-" }
            name += character.lowercased()
        }
    }
}

extension ActionLink.Target {
    /// What to capture, as the selection overlay would have returned it.
    @MainActor
    func captureTarget() async throws -> CaptureTarget {
        switch self {
        case .area(let rect):
            let cocoa = rect.cocoaFlipped
            return .area(cocoa, NSScreen.at(CGPoint(x: cocoa.midX, y: cocoa.midY)))
        case .window(let app):
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // Front to back, normal windows only.
            guard let window = content.windows.first(where: { window in
                guard let owner = window.owningApplication, window.windowLayer == 0, window.frame.width > 1 else { return false }
                return owner.bundleIdentifier.caseInsensitiveCompare(app) == .orderedSame
                    || owner.applicationName.caseInsensitiveCompare(app) == .orderedSame
            }) else { throw ScreenmeError.windowNotFound(app) }
            return .window(window)
        }
    }
}
